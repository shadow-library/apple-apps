enum JSRegexDirection: Sendable {
  case forward
  case backward
}

enum JSRegexAtom: Sendable {
  case character(UInt32)
  case any
  case set(Int)
}

/// `follow` and `need` index `JSRegexProgram.guards`: nil where anything may come next.
/// A greedy atom `backsOff` only when what follows it admits a unit the atom consumes: otherwise no shorter run can go on.
enum JSRegexInstruction: Sendable {
  case atom(JSRegexAtom, JSRegexDirection)
  case repeatAtom(JSRegexAtom, min: Int, max: Int, greedy: Bool, JSRegexDirection, follow: Int?, backsOff: Bool)
  case alternation(Int)
  case jump(Int)
  case save(Int)
  case clearCaptures(Range<Int>)
  case assertStart
  case assertEnd
  case wordBoundary(negated: Bool)
  case lookaround(body: Int, negated: Bool, next: Int)
  case enterLoop(counter: Int)
  case loop(counter: Int, min: Int, max: Int, greedy: Bool, exit: Int, need: Int?)
  case markIteration(register: Int)
  case endIteration(counter: Int, register: Int, min: Int, head: Int)
  case succeed
}

/// A class, so building a matcher retains one reference rather than each of its tables.
final class JSRegexProgram: Sendable {
  let instructions: [JSRegexInstruction]
  let sets: [JSRegexCompiledSet]
  let guards: [JSRegexGuard]
  let alternations: [JSRegexAlternation]
  let mode: JSRegexMode
  let captureCount: Int
  let registerCount: Int
  let counterCount: Int
  let anchoredAtStart: Bool
  let firstUnits: JSRegexFirstUnits?

  var slotCount: Int { 2 * (captureCount + 1) }

  init(_ root: JSRegexNode, captureCount: Int, mode: JSRegexMode) {
    var compiler = JSRegexCompiler(mode: mode)
    compiler.emit(root, .forward, before: .anything)
    compiler.instructions.append(.succeed)
    instructions = compiler.instructions
    sets = compiler.sets
    guards = compiler.guards
    alternations = compiler.alternations
    self.mode = mode
    self.captureCount = captureCount
    registerCount = compiler.registerCount
    counterCount = compiler.counterCount
    anchoredAtStart = root.isAnchoredAtStart
    firstUnits = JSRegexFirstUnits(compiler.flow(root, .forward).need(before: .anything))
  }
}

/// Lookbehind bodies compile backward: terms run right to left, atoms read the unit before the position, and a group saves its end before its start.
/// Every node is emitted with the need of what follows it, so a choice point can skip the choices that cannot go on.
private struct JSRegexCompiler {
  private struct AtomKey: Hashable {
    let set: JSRegexCharacterSet?
    let character: UInt32?
    let direction: JSRegexDirection
  }

  private static let enumerableLimit = 512
  private static let whitespace: [UInt32] = (0...0xFFFF).filter(JSRegexMode.isWhitespace)

  let mode: JSRegexMode
  var instructions: [JSRegexInstruction] = []
  var sets: [JSRegexCompiledSet] = []
  var guards: [JSRegexGuard] = []
  var alternations: [JSRegexAlternation] = []
  var registerCount = 0
  var counterCount = 0
  private var atomNeeds: [AtomKey: JSRegexNeed] = [:]

  init(mode: JSRegexMode) {
    self.mode = mode
  }

  mutating func emit(_ node: JSRegexNode, _ direction: JSRegexDirection, before after: JSRegexNeed) {
    switch node {
    case .character, .any, .set:
      instructions.append(.atom(atom(node), direction))
    case .sequence(let terms):
      let ordered = direction == .forward ? terms : terms.reversed()
      var follows: [JSRegexNeed] = []
      var next = after
      for term in ordered.reversed() {
        follows.append(next)
        next = flow(term, direction).need(before: next)
      }
      for (term, follow) in zip(ordered, follows.reversed()) { emit(term, direction, before: follow) }
    case .alternation(let alternatives):
      emitAlternation(alternatives, direction, before: after)
    case .capture(let body, let index):
      instructions.append(.save(direction == .forward ? 2 * index : 2 * index + 1))
      emit(body, direction, before: after)
      instructions.append(.save(direction == .forward ? 2 * index + 1 : 2 * index))
    case .lookaround(let body, let behind, let negated):
      let start = placeholder()
      emit(body, behind ? .backward : .forward, before: .anything)
      instructions.append(.succeed)
      instructions[start] = .lookaround(body: start + 1, negated: negated, next: instructions.count)
    case .anchor(let anchor):
      instructions.append(instruction(for: anchor))
    case .repetition(let body, let min, let max, let greedy, let captures):
      emitRepetition(body, min: min, max: max, greedy: greedy, captures: captures, direction, before: after)
    }
  }

  /// A lookaround constrains the next unit only when it reads in the same direction and must succeed; `$` going forward and `^` going backward admit only the boundary.
  mutating func flow(_ node: JSRegexNode, _ direction: JSRegexDirection) -> JSRegexFlow {
    switch node {
    case .character, .any, .set:
      return JSRegexFlow(consumed: atomNeed(node, direction), passed: .nothing)
    case .sequence(let terms):
      var flow = JSRegexFlow.transparent
      for term in direction == .forward ? terms : terms.reversed() where flow.passed != .nothing { flow = flow.then(self.flow(term, direction)) }
      return flow
    case .alternation(let alternatives):
      var flow = JSRegexFlow.impossible
      for alternative in alternatives { flow = flow.union(self.flow(alternative, direction)) }
      return flow
    case .capture(let body, _):
      return flow(body, direction)
    case .lookaround(let body, let behind, let negated):
      guard !negated, behind == (direction == .backward) else { return .transparent }
      return JSRegexFlow(consumed: .nothing, passed: flow(body, direction).need(before: .anything))
    case .anchor(.end):
      return direction == .forward ? JSRegexFlow(consumed: .nothing, passed: .boundary) : .transparent
    case .anchor(.start):
      return direction == .backward ? JSRegexFlow(consumed: .nothing, passed: .boundary) : .transparent
    case .anchor:
      return .transparent
    case .repetition(let body, let min, let max, _, _):
      guard max > 0 else { return .transparent }
      let inner = flow(body, direction)
      return JSRegexFlow(consumed: max == 1 ? inner.consumed : inner.consumed.union(inner.passed), passed: min == 0 ? .anything : inner.passed)
    }
  }

  private mutating func placeholder() -> Int {
    instructions.append(.succeed)
    return instructions.count - 1
  }

  private mutating func atom(_ node: JSRegexNode) -> JSRegexAtom {
    switch node {
    case .character(let value): return .character(mode.ignoreCase ? JSCaseFolding.canonical(value, unicode: mode.unicode) : value)
    case .set(let set):
      sets.append(JSRegexCompiledSet(set, mode: mode))
      return .set(sets.count - 1)
    default: return .any
    }
  }

  private mutating func guardIndex(_ need: JSRegexNeed, _ direction: JSRegexDirection) -> Int? {
    guard need != .anything else { return nil }
    guards.append(JSRegexGuard(need: need, direction: direction))
    return guards.count - 1
  }

  private func instruction(for anchor: JSRegexAnchor) -> JSRegexInstruction {
    switch anchor {
    case .start: .assertStart
    case .end: .assertEnd
    case .wordBoundary: .wordBoundary(negated: false)
    case .notWordBoundary: .wordBoundary(negated: true)
    }
  }

  /// Wider disjunctions nest their tail, which keeps the order in which alternatives are tried.
  private mutating func emitAlternation(_ alternatives: [JSRegexNode], _ direction: JSRegexDirection, before after: JSRegexNeed) {
    let capacity = JSRegexAlternation.capacity
    guard alternatives.count <= capacity else {
      emitAlternation(Array(alternatives.prefix(capacity - 1)) + [.alternation(Array(alternatives.dropFirst(capacity - 1)))], direction, before: after)
      return
    }
    var needs: [JSRegexNeed] = []
    for alternative in alternatives { needs.append(flow(alternative, direction).need(before: after)) }
    let dispatch = placeholder()
    var entries: [Int] = []
    var exits: [Int] = []
    for (offset, alternative) in alternatives.enumerated() {
      entries.append(instructions.count)
      emit(alternative, direction, before: after)
      if offset < alternatives.count - 1 { exits.append(placeholder()) }
    }
    for exit in exits { instructions[exit] = .jump(instructions.count) }
    alternations.append(JSRegexAlternation(entries: entries, needs: needs, direction))
    instructions[dispatch] = .alternation(alternations.count - 1)
  }

  /// After an iteration comes another one or what follows the loop; with at most one iteration, only what follows.
  private mutating func emitRepetition(
    _ body: JSRegexNode, min: Int, max: Int, greedy: Bool, captures: Range<Int>, _ direction: JSRegexDirection, before after: JSRegexNeed
  ) {
    guard max > 0 else { return }
    switch body {
    case .character, .any, .set:
      let backsOff = after.overlaps(atomNeed(body, direction))
      instructions.append(.repeatAtom(atom(body), min: min, max: max, greedy: greedy, direction, follow: guardIndex(after, direction), backsOff: backsOff))
      return
    default:
      break
    }
    let inner = flow(body, direction)
    let afterIteration = max == 1 ? after : inner.consumed.union(inner.passed).union(after)
    let counter = counterCount
    let register = registerCount
    counterCount += 1
    registerCount += 1
    instructions.append(.enterLoop(counter: counter))
    let head = placeholder()
    instructions.append(.markIteration(register: register))
    if !captures.isEmpty { instructions.append(.clearCaptures((2 * captures.lowerBound)..<(2 * captures.upperBound))) }
    emit(body, direction, before: afterIteration)
    instructions.append(.endIteration(counter: counter, register: register, min: min, head: head))
    let need = guardIndex(inner.need(before: afterIteration), direction)
    instructions[head] = .loop(counter: counter, min: min, max: max, greedy: greedy, exit: instructions.count, need: need)
  }

  /// Under `i` an atom admits every unit of its case orbit; an astral member admits its first surrogate going forward and its second going backward.
  private mutating func atomNeed(_ node: JSRegexNode, _ direction: JSRegexDirection) -> JSRegexNeed {
    let key: AtomKey
    switch node {
    case .character(let value): key = AtomKey(set: nil, character: value, direction: direction)
    case .set(let set): key = AtomKey(set: set, character: nil, direction: direction)
    default: return JSRegexNeed(asciiLow: ~(1 << 0x0A | 1 << 0x0D), asciiHigh: ~0, others: nil, boundary: false)
    }
    if let known = atomNeeds[key] { return known }
    let need: JSRegexNeed
    if let set = key.set {
      let compiled = JSRegexCompiledSet(set, mode: mode)
      let others = members(of: set).map { Set(units(of: $0, direction).filter { $0 >= 0x80 }) }
      need = JSRegexNeed(asciiLow: compiled.asciiLow, asciiHigh: compiled.asciiHigh, others: others, boundary: false)
    } else {
      need = JSRegexNeed(units: units(of: [key.character ?? 0], direction))
    }
    atomNeeds[key] = need
    return need
  }

  private func members(of set: JSRegexCharacterSet) -> [UInt32]? {
    guard !set.negated else { return nil }
    var members: [UInt32] = []
    for item in set.items {
      switch item {
      case .range(let lower, let upper):
        guard upper - lower < Self.enumerableLimit else { return nil }
        members.append(contentsOf: lower...upper)
      case .digit(negated: false): members.append(contentsOf: 0x30...0x39)
      case .space(negated: false): members.append(contentsOf: Self.whitespace)
      case .word(negated: false):
        members.append(contentsOf: JSRegexMode.asciiWordCharacters + (mode.unicode && mode.ignoreCase ? Array(JSCaseFolding.unicodeExtraWordCharacters) : []))
      default: return nil
      }
      if members.count > Self.enumerableLimit { return nil }
    }
    return members
  }

  private func units(of values: [UInt32], _ direction: JSRegexDirection) -> [UInt16] {
    let all = mode.ignoreCase ? values.flatMap { JSCaseFolding.equivalents($0, unicode: mode.unicode) } : values
    return all.map { value in
      guard value > 0xFFFF else { return UInt16(truncatingIfNeeded: value) }
      let offset = value - 0x1_0000
      return direction == .forward ? UInt16(0xD800 + (offset >> 10)) : UInt16(0xDC00 + (offset & 0x3FF))
    }
  }
}
