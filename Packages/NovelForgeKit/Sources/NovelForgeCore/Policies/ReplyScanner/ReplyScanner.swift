struct ReplyScanner: Sendable {
  private enum Phase {
    case preamble
    case keyStart
    case inKey
    case afterKey
    case valueStart
    case inString
    case inScalar
    case afterValue
    case done
  }

  private enum Container {
    case object
    case array
  }

  private enum Sink {
    case discard
    case key
    case reply
  }

  private enum TrackedKey {
    case reply
    case changeSet
  }

  private enum Escape {
    case none
    case pending
    case unicode(value: UInt16, digits: Int)
  }

  private enum ElementPhase {
    case none
    case open
    case closed
  }

  private static let changeSetDepth = 2

  private var phase = Phase.preamble
  private var stack: [Container] = []
  private var sink = Sink.discard
  private var pendingKey: [UInt16] = []
  private var keyOverflowed = false
  private var valueKey: TrackedKey?
  private var escape = Escape.none
  private var replySeen = false
  private var changeSetOpen = false
  private var elementPhase = ElementPhase.none
  private var elementUnits: [UInt16] = []
  private var pendingHighSurrogate: UInt16?
  private var replyUnits: [UInt16] = []
  private var events: [ReplyScanEvent] = []

  var state: ReplyScanState {
    if phase == .done { return .completed }
    return replySeen ? .replyFound : .awaitingReply
  }

  mutating func consume(_ chunk: String) -> [ReplyScanEvent] {
    consume(utf16: Array(chunk.utf16))
  }

  mutating func consume(utf16 units: [UInt16]) -> [ReplyScanEvent] {
    var index = 0
    while index < units.count && phase != .done {
      let unit = units[index]
      guard step(unit) else { continue }
      index += 1
      guard elementPhase != .none else { continue }
      elementUnits.append(unit)
      if elementPhase == .closed { finishElement() }
    }
    return takeEvents()
  }

  mutating func finish() -> [ReplyScanEvent] {
    flushPendingHighSurrogate()
    return takeEvents()
  }

  private mutating func takeEvents() -> [ReplyScanEvent] {
    flushReply()
    let taken = events
    events = []
    return taken
  }

  private mutating func flushReply() {
    guard !replyUnits.isEmpty else { return }
    events.append(.reply(String(decoding: replyUnits, as: UTF16.self)))
    replyUnits.removeAll(keepingCapacity: true)
  }

  // A high surrogate the stream never completes, and a lone low surrogate, become U+FFFD.
  private mutating func emitReply(_ unit: UInt16) {
    if let high = pendingHighSurrogate {
      pendingHighSurrogate = nil
      if JSONCodeUnit.isLowSurrogate(unit) {
        replyUnits.append(high)
        replyUnits.append(unit)
        return
      }
      replyUnits.append(JSONCodeUnit.replacement)
    }
    if JSONCodeUnit.isHighSurrogate(unit) {
      pendingHighSurrogate = unit
    } else if JSONCodeUnit.isLowSurrogate(unit) {
      replyUnits.append(JSONCodeUnit.replacement)
    } else {
      replyUnits.append(unit)
    }
  }

  private mutating func flushPendingHighSurrogate() {
    guard pendingHighSurrogate != nil else { return }
    pendingHighSurrogate = nil
    replyUnits.append(JSONCodeUnit.replacement)
  }

  private mutating func finishElement() {
    let units = elementUnits
    elementPhase = .none
    elementUnits = []
    guard let element = ChangeSetElement(units: units) else { return }
    flushReply()
    events.append(.element(element))
  }

  private mutating func step(_ unit: UInt16) -> Bool {
    switch phase {
    case .preamble:
      if unit == JSONCodeUnit.openBrace {
        stack.append(.object)
        phase = .keyStart
      }
      return true
    case .keyStart:
      if unit == JSONCodeUnit.quote {
        sink = .key
        pendingKey.removeAll(keepingCapacity: true)
        keyOverflowed = false
        phase = .inKey
      } else if unit == JSONCodeUnit.closeBrace {
        closeContainer()
      }
      return true
    case .inKey:
      if consumeStringUnit(unit) {
        valueKey = trackedKey()
        phase = .afterKey
      }
      return true
    case .afterKey:
      if unit == JSONCodeUnit.colon { phase = .valueStart }
      return true
    case .valueStart:
      return startValue(unit)
    case .inString:
      guard consumeStringUnit(unit) else { return true }
      phase = .afterValue
      if sink == .reply { flushPendingHighSurrogate() }
      return true
    case .inScalar:
      guard JSONCodeUnit.isScalarDelimiter(unit) else { return true }
      phase = .afterValue
      return false
    case .afterValue:
      if unit == JSONCodeUnit.comma {
        phase = stack.last == .array ? .valueStart : .keyStart
      } else if unit == JSONCodeUnit.closeBrace || unit == JSONCodeUnit.closeBracket {
        closeContainer()
      }
      return true
    case .done:
      return true
    }
  }

  private mutating func startValue(_ unit: UInt16) -> Bool {
    if JSONCodeUnit.isScriptWhitespace(unit) { return true }
    if unit == JSONCodeUnit.closeBracket {
      closeContainer()
      return true
    }

    let key = valueKey
    valueKey = nil
    if unit == JSONCodeUnit.openBrace && changeSetOpen && stack.count == Self.changeSetDepth {
      elementUnits.removeAll(keepingCapacity: true)
      elementPhase = .open
    }

    switch unit {
    case JSONCodeUnit.quote:
      sink = key == .reply && !replySeen ? .reply : .discard
      if sink == .reply { replySeen = true }
      phase = .inString
    case JSONCodeUnit.openBrace:
      stack.append(.object)
      phase = .keyStart
    case JSONCodeUnit.openBracket:
      if key == .changeSet { changeSetOpen = true }
      stack.append(.array)
      phase = .valueStart
    default:
      phase = .inScalar
      return false
    }
    return true
  }

  private func trackedKey() -> TrackedKey? {
    guard stack.count == 1, !keyOverflowed else { return nil }
    if pendingKey == JSONCodeUnit.replyKey { return .reply }
    return pendingKey == JSONCodeUnit.changeSetKey ? .changeSet : nil
  }

  private mutating func closeContainer() {
    stack.removeLast()
    let depth = stack.count
    if elementPhase == .open && depth == Self.changeSetDepth { elementPhase = .closed }
    if changeSetOpen && depth < Self.changeSetDepth { changeSetOpen = false }
    if depth > 0 {
      phase = .afterValue
      return
    }
    if replySeen {
      phase = .done
      return
    }
    resetForPreamble()
  }

  private mutating func resetForPreamble() {
    phase = .preamble
    sink = .discard
    pendingKey.removeAll(keepingCapacity: true)
    keyOverflowed = false
    valueKey = nil
    escape = .none
    changeSetOpen = false
    elementPhase = .none
    elementUnits.removeAll(keepingCapacity: true)
  }

  private mutating func consumeStringUnit(_ unit: UInt16) -> Bool {
    switch escape {
    case .unicode(let value, let digits):
      guard let digit = JSONCodeUnit.hexValue(unit) else {
        escape = .none
        return consumeStringUnit(unit)
      }
      let next = value << 4 | digit
      if digits + 1 == 4 {
        escape = .none
        append(next)
      } else {
        escape = .unicode(value: next, digits: digits + 1)
      }
      return false
    case .pending:
      escape = unit == JSONCodeUnit.lowerU ? .unicode(value: 0, digits: 0) : .none
      if unit != JSONCodeUnit.lowerU { append(JSONCodeUnit.simpleEscapes[unit] ?? unit) }
      return false
    case .none:
      if unit == JSONCodeUnit.backslash {
        escape = .pending
        return false
      }
      if unit == JSONCodeUnit.quote { return true }
      append(unit)
      return false
    }
  }

  private mutating func append(_ unit: UInt16) {
    switch sink {
    case .discard:
      return
    case .key:
      if pendingKey.count < JSONCodeUnit.changeSetKey.count {
        pendingKey.append(unit)
      } else {
        keyOverflowed = true
      }
    case .reply:
      emitReply(unit)
    }
  }
}
