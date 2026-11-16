/// A backtracking matcher with an explicit stack, so input length never deepens the call stack; only nested lookarounds recurse.
struct JSRegexMachine {
  private struct Read {
    let value: UInt32
    let next: Int
  }

  private enum Frame {
    case resume(pc: Int, position: Int)
    case backOff(pc: Int, position: Int, floor: Int, JSRegexDirection)
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
  private let instructions: [JSRegexInstruction]
  private let sets: [JSRegexCompiledSet]
  private let unicode: Bool
  private let ignoreCase: Bool
  private(set) var slots: [Int]
  private var registers: [Int]
  private var counters: [Int]
  private var stack: [Frame] = []

  init(_ program: JSRegexProgram, units: [UInt16]) {
    self.program = program
    self.units = units
    instructions = program.instructions
    sets = program.sets
    unicode = program.mode.unicode
    ignoreCase = program.mode.ignoreCase
    slots = Array(repeating: -1, count: program.slotCount)
    registers = Array(repeating: -1, count: program.registerCount)
    counters = Array(repeating: 0, count: program.counterCount)
  }

  /// The capture slots of a match starting exactly at `start`, as UTF-16 offsets with -1 for an unmatched group.
  mutating func match(at start: Int) -> [Int]? {
    if program.anchoredAtStart, start != 0 { return nil }
    if let firstUnits = program.firstUnits, start >= units.count || !firstUnits.contains(units[start]) { return nil }
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
  mutating func search(from start: Int) -> [Int]? {
    var index = max(start, 0)
    if unicode, index > 0, index < units.count, Self.isLow(units[index]), Self.isHigh(units[index - 1]) { index -= 1 }
    let firstUnits = program.firstUnits
    while index <= units.count {
      if let firstUnits {
        index = firstUnits.next(in: units, from: index, unicode: unicode)
        if index >= units.count { return nil }
      }
      if let slots = match(at: index) { return slots }
      index = advance(index)
    }
    return nil
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
      var matched = true
      switch instructions[pc] {
      case .atom(let atom, let direction):
        if let next = step(atom, position, direction) {
          position = next
          pc += 1
        } else {
          matched = false
        }
      case .repeatAtom(let atom, let min, let max, let greedy, let direction):
        if let next = repeatAtom(atom, from: position, min: min, max: max, greedy: greedy, direction, pc: pc) {
          position = next
          pc += 1
        } else {
          matched = false
        }
      case .split(let primary, let alternate):
        stack.append(.resume(pc: alternate, position: position))
        pc = primary
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
      case .loop(let counter, let min, let max, let greedy, let exit):
        let count = counters[counter]
        if count < min {
          pc += 1
        } else if count >= max {
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

  private mutating func repeatAtom(_ atom: JSRegexAtom, from start: Int, min: Int, max: Int, greedy: Bool, _ direction: JSRegexDirection, pc: Int) -> Int? {
    var position = start
    var count = 0
    while count < min {
      guard let next = step(atom, position, direction) else { return nil }
      position = next
      count += 1
    }
    if !greedy {
      if count < max { stack.append(.extend(pc: pc, position: position, count: count)) }
      return position
    }
    let floor = position
    while count < max, let next = step(atom, position, direction) {
      position = next
      count += 1
    }
    if position != floor { stack.append(.backOff(pc: pc + 1, position: position, floor: floor, direction)) }
    return position
  }

  private mutating func backtrack(to base: Int) -> (Int, Int)? {
    while stack.count > base {
      switch stack.removeLast() {
      case .resume(let pc, let position):
        return (pc, position)
      case .backOff(let pc, let position, let floor, let direction):
        let previous = stepBack(position, toward: floor, direction)
        if previous != floor { stack.append(.backOff(pc: pc, position: previous, floor: floor, direction)) }
        return (pc, previous)
      case .extend(let pc, let position, let count):
        guard case .repeatAtom(let atom, _, let max, _, let direction) = instructions[pc], let next = step(atom, position, direction) else { continue }
        if count + 1 < max { stack.append(.extend(pc: pc, position: next, count: count + 1)) }
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
      return sets[index].contains(value) ? next : nil
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
