enum JSRegexDirection: Sendable {
  case forward
  case backward
}

enum JSRegexAtom: Sendable {
  case character(UInt32)
  case any
  case set(Int)
}

enum JSRegexInstruction: Sendable {
  case atom(JSRegexAtom, JSRegexDirection)
  case repeatAtom(JSRegexAtom, min: Int, max: Int, greedy: Bool, JSRegexDirection)
  case split(Int, Int)
  case jump(Int)
  case save(Int)
  case clearCaptures(Range<Int>)
  case assertStart
  case assertEnd
  case wordBoundary(negated: Bool)
  case lookaround(body: Int, negated: Bool, next: Int)
  case enterLoop(counter: Int)
  case loop(counter: Int, min: Int, max: Int, greedy: Bool, exit: Int)
  case markIteration(register: Int)
  case endIteration(counter: Int, register: Int, min: Int, head: Int)
  case succeed
}

struct JSRegexProgram: Sendable {
  let instructions: [JSRegexInstruction]
  let sets: [JSRegexCompiledSet]
  let mode: JSRegexMode
  let captureCount: Int
  let registerCount: Int
  let counterCount: Int
  let anchoredAtStart: Bool
  let firstUnits: JSRegexFirstUnits?

  var slotCount: Int { 2 * (captureCount + 1) }

  init(_ root: JSRegexNode, captureCount: Int, mode: JSRegexMode) {
    var compiler = JSRegexCompiler(mode: mode)
    compiler.emit(root, .forward)
    compiler.instructions.append(.succeed)
    instructions = compiler.instructions
    sets = compiler.sets
    self.mode = mode
    self.captureCount = captureCount
    registerCount = compiler.registerCount
    counterCount = compiler.counterCount
    anchoredAtStart = root.isAnchoredAtStart
    firstUnits = JSRegexFirstUnits(root, mode: mode)
  }
}

/// Lookbehind bodies compile backward: terms run right to left, atoms read the unit before the position, and a group saves its end before its start.
private struct JSRegexCompiler {
  let mode: JSRegexMode
  var instructions: [JSRegexInstruction] = []
  var sets: [JSRegexCompiledSet] = []
  var registerCount = 0
  var counterCount = 0

  init(mode: JSRegexMode) {
    self.mode = mode
  }

  mutating func emit(_ node: JSRegexNode, _ direction: JSRegexDirection) {
    switch node {
    case .character, .any, .set:
      instructions.append(.atom(atom(node), direction))
    case .sequence(let terms):
      for term in direction == .forward ? terms : terms.reversed() { emit(term, direction) }
    case .alternation(let alternatives):
      emitAlternation(alternatives, direction)
    case .capture(let body, let index):
      instructions.append(.save(direction == .forward ? 2 * index : 2 * index + 1))
      emit(body, direction)
      instructions.append(.save(direction == .forward ? 2 * index + 1 : 2 * index))
    case .lookaround(let body, let behind, let negated):
      let start = placeholder()
      emit(body, behind ? .backward : .forward)
      instructions.append(.succeed)
      instructions[start] = .lookaround(body: start + 1, negated: negated, next: instructions.count)
    case .anchor(let anchor):
      instructions.append(instruction(for: anchor))
    case .repetition(let body, let min, let max, let greedy, let captures):
      emitRepetition(body, min: min, max: max, greedy: greedy, captures: captures, direction)
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

  private func instruction(for anchor: JSRegexAnchor) -> JSRegexInstruction {
    switch anchor {
    case .start: .assertStart
    case .end: .assertEnd
    case .wordBoundary: .wordBoundary(negated: false)
    case .notWordBoundary: .wordBoundary(negated: true)
    }
  }

  private mutating func emitAlternation(_ alternatives: [JSRegexNode], _ direction: JSRegexDirection) {
    var exits: [Int] = []
    for (offset, alternative) in alternatives.enumerated() {
      guard offset < alternatives.count - 1 else {
        emit(alternative, direction)
        break
      }
      let split = placeholder()
      emit(alternative, direction)
      exits.append(placeholder())
      instructions[split] = .split(split + 1, instructions.count)
    }
    for exit in exits { instructions[exit] = .jump(instructions.count) }
  }

  private mutating func emitRepetition(_ body: JSRegexNode, min: Int, max: Int, greedy: Bool, captures: Range<Int>, _ direction: JSRegexDirection) {
    guard max > 0 else { return }
    switch body {
    case .character, .any, .set:
      instructions.append(.repeatAtom(atom(body), min: min, max: max, greedy: greedy, direction))
      return
    default:
      break
    }
    let counter = counterCount
    let register = registerCount
    counterCount += 1
    registerCount += 1
    instructions.append(.enterLoop(counter: counter))
    let head = placeholder()
    instructions.append(.markIteration(register: register))
    if !captures.isEmpty { instructions.append(.clearCaptures((2 * captures.lowerBound)..<(2 * captures.upperBound))) }
    emit(body, direction)
    instructions.append(.endIteration(counter: counter, register: register, min: min, head: head))
    instructions[head] = .loop(counter: counter, min: min, max: max, greedy: greedy, exit: instructions.count)
  }
}
