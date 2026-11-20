/// A backtracking matcher with an explicit stack, so input length never deepens the call stack; only nested lookarounds recurse.
/// A choice whose guard refuses the input is never pushed, and a greedy atom backs off straight to a position its follow admits.
public struct JSRegexMachine {
  private struct Read {
    let value: UInt32
    let next: Int
  }

  private enum Frame {
    case resume(pc: Int, position: Int)
    case alternative(table: Int, remaining: UInt64, position: Int)
    case backOff(pc: Int, position: Int, floor: Int)
    case extend(pc: Int, position: Int, count: Int)
    case restoreSlot(Int, Int)
    case restoreRegister(Int, Int)
    case restoreCounter(Int, Int)

    var isRestore: Bool {
      switch self {
      case .restoreSlot, .restoreRegister, .restoreCounter: true
      default: false
      }
    }
  }

  let units: [UInt16]
  private let program: JSRegexProgram
  private let unicode: Bool
  private let ignoreCase: Bool
  private(set) var slots: [Int]
  private var registers: [Int]
  private var counters: [Int]
  private var stack: [Frame] = []
  /// Instructions run, choices taken back and units scanned.
  private(set) var steps = 0

  init(_ program: JSRegexProgram, units: [UInt16]) {
    self.program = program
    self.units = units
    unicode = program.mode.unicode
    ignoreCase = program.mode.ignoreCase
    slots = Array(repeating: -1, count: program.slotCount)
    registers = Array(repeating: -1, count: program.registerCount)
    counters = Array(repeating: 0, count: program.counterCount)
  }

  /// The capture slots of a match starting exactly at `start`, as UTF-16 offsets with -1 for an unmatched group.
  mutating func match(at start: Int) -> [Int]? {
    if program.anchoredAtStart, start != 0 { return nil }
    if let firstUnits = program.firstUnits, !firstUnits.admits(units, at: start) { return nil }
    var index = 0
    while index < slots.count {
      slots[index] = -1
      index += 1
    }
    stack.removeAll(keepingCapacity: true)
    guard let end = run(from: 0, at: start) else { return nil }
    slots[0] = start
    slots[1] = end
    return slots
  }

  /// The first match starting at or after `start`; with `u`, a start inside a surrogate pair begins at the pair, as RegExpBuiltinExec reads code points.
  public mutating func search(from start: Int) -> [Int]? {
    var index = max(start, 0)
    if unicode, index > 0, index < units.count, Self.isLow(units[index]), Self.isHigh(units[index - 1]) { index -= 1 }
    while index <= units.count {
      if let firstUnits = program.firstUnits {
        let next = firstUnits.next(in: units, from: index, unicode: unicode)
        steps += next - index
        index = next
        if index > units.count { return nil }
      }
      if let slots = match(at: index) { return slots }
      index = advance(index)
    }
    return nil
  }

  /// Every match from offset 0, an empty match stepping one code unit (one code point with `u`), as `matchAll` and a global `match` or `replace` do.
  mutating func allMatches() -> [[Int]] {
    var matches: [[Int]] = []
    var lastIndex = 0
    while let slots = search(from: lastIndex) {
      matches.append(slots)
      lastIndex = slots[1] == slots[0] ? advance(slots[1]) : slots[1]
    }
    return matches
  }

  func advance(_ index: Int) -> Int {
    guard unicode, index + 1 < units.count, Self.isHigh(units[index]), Self.isLow(units[index + 1]) else { return index + 1 }
    return index + 2
  }

  private mutating func run(from entry: Int, at start: Int) -> Int? {
    let base = stack.count
    var pc = entry
    var position = start
    while true {
      steps += 1
      var matched = true
      switch program.instructions[pc] {
      case .atom(let atom, let direction):
        if let next = step(atom, position, direction) {
          position = next
          pc += 1
        } else {
          matched = false
        }
      case .repeatAtom(let atom, let min, let max, let greedy, let direction, let follow, let backsOff):
        if let next = repeatAtom(atom, from: position, min: min, max: max, greedy: greedy, direction, follow: follow, backsOff: backsOff, pc: pc) {
          position = next
          pc += 1
        } else {
          matched = false
        }
      case .alternation(let table):
        let candidates = program.alternations[table].candidates(in: units, at: position)
        if candidates == 0 {
          matched = false
        } else {
          let remaining = candidates & (candidates - 1)
          if remaining != 0 { stack.append(.alternative(table: table, remaining: remaining, position: position)) }
          pc = program.alternations[table].entries[candidates.trailingZeroBitCount]
        }
      case .jump(let target):
        pc = target
      case .save(let slot):
        stack.append(.restoreSlot(slot, slots[slot]))
        slots[slot] = position
        pc += 1
      case .clearCaptures(let range):
        for slot in range where slots[slot] != -1 {
          stack.append(.restoreSlot(slot, slots[slot]))
          slots[slot] = -1
        }
        pc += 1
      case .assertStart:
        matched = position == 0
        pc += 1
      case .assertEnd:
        matched = position == units.count
        pc += 1
      case .wordBoundary(let negated):
        let before = position > 0 && program.mode.isWordCharacter(UInt32(units[position - 1]))
        let after = position < units.count && program.mode.isWordCharacter(UInt32(units[position]))
        matched = (before != after) != negated
        pc += 1
      case .lookaround(let body, let negated, let next):
        let mark = stack.count
        let found = run(from: body, at: position) != nil
        if found, negated { unwind(to: mark) }
        if found, !negated { keepRestores(above: mark) }
        matched = found != negated
        pc = next
      case .enterLoop(let counter):
        stack.append(.restoreCounter(counter, counters[counter]))
        counters[counter] = 0
        pc += 1
      case .loop(let counter, let min, let max, let greedy, let exit, let need):
        let count = counters[counter]
        let enters = need.map { program.guards[$0].admits(units, at: position) } ?? true
        if count < min {
          matched = enters
          pc += 1
        } else if count >= max || !enters {
          pc = exit
        } else if greedy {
          stack.append(.resume(pc: exit, position: position))
          pc += 1
        } else {
          stack.append(.resume(pc: pc + 1, position: position))
          pc = exit
        }
      case .markIteration(let register):
        stack.append(.restoreRegister(register, registers[register]))
        registers[register] = position
        pc += 1
      case .endIteration(let counter, let register, let min, let head):
        if counters[counter] >= min, registers[register] == position {
          matched = false
        } else {
          stack.append(.restoreCounter(counter, counters[counter]))
          counters[counter] += 1
          pc = head
        }
      case .succeed:
        return position
      }
      if matched { continue }
      guard let resumed = backtrack(to: base) else { return nil }
      (pc, position) = resumed
    }
  }

  private mutating func repeatAtom(
    _ atom: JSRegexAtom, from start: Int, min: Int, max: Int, greedy: Bool, _ direction: JSRegexDirection, follow: Int?, backsOff: Bool, pc: Int
  ) -> Int? {
    var position = start
    var count = 0
    while count < min {
      guard let next = step(atom, position, direction) else { return nil }
      position = next
      count += 1
    }
    if !greedy {
      if !admits(follow, position, direction) {
        guard let (longer, longerCount) = lengthen(atom, from: position, count: count, max: max, direction, follow: follow) else { return nil }
        position = longer
        count = longerCount
      }
      if count < max { stack.append(.extend(pc: pc, position: position, count: count)) }
      return position
    }
    let floor = position
    position = consume(atom, from: position, upTo: max - count, direction)
    steps += abs(position - floor)
    if admits(follow, position, direction) {
      if backsOff, position != floor { stack.append(.backOff(pc: pc, position: position, floor: floor)) }
      return position
    }
    guard backsOff, let resumed = retreat(from: position, to: floor, direction, follow: follow) else { return nil }
    if resumed != floor { stack.append(.backOff(pc: pc, position: resumed, floor: floor)) }
    return resumed
  }

  /// As many matches of `atom` as there are, up to `limit`; the ASCII units of a forward run are tested without decoding.
  private func consume(_ atom: JSRegexAtom, from start: Int, upTo limit: Int, _ direction: JSRegexDirection) -> Int {
    var position = start
    var count = 0
    if direction == .forward, case .set(let index) = atom {
      let set = program.sets[index]
      while count < limit, position < units.count {
        let unit = units[position]
        if unit < 128 {
          guard set.contains(UInt32(unit)) else { break }
          position += 1
        } else {
          guard let next = step(atom, position, direction) else { break }
          position = next
        }
        count += 1
      }
      return position
    }
    while count < limit, let next = step(atom, position, direction) {
      position = next
      count += 1
    }
    return position
  }

  /// The nearest position before `position`, down to `floor`, where what follows the atom can go on.
  private mutating func retreat(from position: Int, to floor: Int, _ direction: JSRegexDirection, follow: Int?) -> Int? {
    if !unicode, direction == .forward, let follow {
      let need = program.guards[follow].need
      var candidate = position
      while candidate > floor {
        candidate -= 1
        if need.admits(units[candidate]) {
          steps += position - candidate
          return candidate
        }
      }
      steps += position - floor
      return nil
    }
    var candidate = position
    repeat {
      guard candidate != floor else {
        steps += abs(position - floor)
        return nil
      }
      candidate = stepBack(candidate, toward: floor, direction)
    } while !admits(follow, candidate, direction)
    steps += abs(position - candidate)
    return candidate
  }

  /// A lazy atom takes at least one more unit, then more while what follows it cannot go on.
  private mutating func lengthen(
    _ atom: JSRegexAtom, from start: Int, count startCount: Int, max: Int, _ direction: JSRegexDirection, follow: Int?
  ) -> (Int, Int)? {
    var position = start
    var count = startCount
    repeat {
      guard count < max, let next = step(atom, position, direction) else { return nil }
      position = next
      count += 1
      steps += 1
    } while !admits(follow, position, direction)
    return (position, count)
  }

  private func admits(_ follow: Int?, _ position: Int, _ direction: JSRegexDirection) -> Bool {
    guard let follow else { return true }
    return program.guards[follow].need.admits(units, at: position, direction)
  }

  private mutating func backtrack(to base: Int) -> (Int, Int)? {
    while stack.count > base {
      steps += 1
      switch stack.removeLast() {
      case .resume(let pc, let position):
        return (pc, position)
      case .alternative(let table, let remaining, let position):
        let rest = remaining & (remaining - 1)
        if rest != 0 { stack.append(.alternative(table: table, remaining: rest, position: position)) }
        return (program.alternations[table].entries[remaining.trailingZeroBitCount], position)
      case .backOff(let pc, let position, let floor):
        guard case .repeatAtom(_, _, _, _, let direction, let follow, _) = program.instructions[pc],
          let previous = retreat(from: position, to: floor, direction, follow: follow)
        else { continue }
        if previous != floor { stack.append(.backOff(pc: pc, position: previous, floor: floor)) }
        return (pc + 1, previous)
      case .extend(let pc, let position, let count):
        guard case .repeatAtom(let atom, _, let max, _, let direction, let follow, _) = program.instructions[pc],
          let (next, nextCount) = lengthen(atom, from: position, count: count, max: max, direction, follow: follow)
        else { continue }
        if nextCount < max { stack.append(.extend(pc: pc, position: next, count: nextCount)) }
        return (pc + 1, next)
      case .restoreSlot(let slot, let value):
        slots[slot] = value
      case .restoreRegister(let register, let value):
        registers[register] = value
      case .restoreCounter(let counter, let value):
        counters[counter] = value
      }
    }
    return nil
  }

  private mutating func unwind(to mark: Int) {
    while stack.count > mark {
      switch stack.removeLast() {
      case .restoreSlot(let slot, let value): slots[slot] = value
      case .restoreRegister(let register, let value): registers[register] = value
      case .restoreCounter(let counter, let value): counters[counter] = value
      default: continue
      }
    }
  }

  /// A lookaround is atomic: its choices are dropped, while the undo records of the captures it set stay for the outer match.
  private mutating func keepRestores(above mark: Int) {
    var write = mark
    for read in mark..<stack.count where stack[read].isRestore {
      stack[write] = stack[read]
      write += 1
    }
    stack.removeSubrange(write...)
  }

  private func step(_ atom: JSRegexAtom, _ position: Int, _ direction: JSRegexDirection) -> Int? {
    guard let read = read(position, direction) else { return nil }
    let value = read.value
    let next = read.next
    switch atom {
    case .character(let expected):
      let actual = ignoreCase ? JSCaseFolding.canonical(value, unicode: unicode) : value
      return actual == expected ? next : nil
    case .any:
      return JSRegexMode.isLineTerminator(value) ? nil : next
    case .set(let index):
      return program.sets[index].contains(value) ? next : nil
    }
  }

  private func read(_ position: Int, _ direction: JSRegexDirection) -> Read? {
    switch direction {
    case .forward:
      guard position < units.count else { return nil }
      let unit = units[position]
      if unicode, Self.isHigh(unit), position + 1 < units.count, Self.isLow(units[position + 1]) {
        return Read(value: Self.combine(unit, units[position + 1]), next: position + 2)
      }
      return Read(value: UInt32(unit), next: position + 1)
    case .backward:
      guard position > 0 else { return nil }
      let unit = units[position - 1]
      if unicode, Self.isLow(unit), position >= 2, Self.isHigh(units[position - 2]) {
        return Read(value: Self.combine(units[position - 2], unit), next: position - 2)
      }
      return Read(value: UInt32(unit), next: position - 1)
    }
  }

  private func stepBack(_ position: Int, toward floor: Int, _ direction: JSRegexDirection) -> Int {
    switch direction {
    case .forward:
      if unicode, position - 2 >= floor, Self.isLow(units[position - 1]), Self.isHigh(units[position - 2]) { return position - 2 }
      return position - 1
    case .backward:
      if unicode, position + 2 <= floor, Self.isHigh(units[position]), Self.isLow(units[position + 1]) { return position + 2 }
      return position + 1
    }
  }

  static func isHigh(_ unit: UInt16) -> Bool { unit & 0xFC00 == 0xD800 }

  static func isLow(_ unit: UInt16) -> Bool { unit & 0xFC00 == 0xDC00 }

  private static func combine(_ high: UInt16, _ low: UInt16) -> UInt32 {
    0x1_0000 + (UInt32(high - 0xD800) << 10) + UInt32(low - 0xDC00)
  }
}
