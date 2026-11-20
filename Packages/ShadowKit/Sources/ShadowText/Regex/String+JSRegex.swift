extension String {
  public func jsSearch(_ pattern: JSRegex) -> Int {
    pattern.firstMatchSlots(in: jsCodeUnits, from: 0)?[0] ?? -1
  }

  /// `[...text.matchAll(re)]`, and `text.match(re)` for a global `re` as `.map(\.text)` (empty where JavaScript gives null); unlike `matchAll`, a non-global `re` is not refused.
  public func jsMatchAll(_ pattern: JSRegex) -> [JSRegexMatch] {
    let units = jsCodeUnits
    return pattern.allMatchSlots(in: units).map { JSRegexMatch(slots: $0, units: units) }
  }

  /// `text.replace(re, replacement)`, expanding `$$`, `$&`, `` $` ``, `$'` and `$1`…`$99`; a global `re` replaces every match.
  public func jsReplace(_ pattern: JSRegex, _ replacement: String) -> String {
    let template = replacement.jsCodeUnits
    return replacing(pattern) { slots, units in Self.substitute(template, slots: slots, units: units) }
  }

  public func jsReplace(_ pattern: JSRegex, _ replacer: (JSRegexMatch) -> String) -> String {
    replacing(pattern) { slots, units in replacer(JSRegexMatch(slots: slots, units: units)).jsCodeUnits }
  }

  /// `text.split(re, limit)`; a nil `limit` is `undefined`. JavaScript puts `undefined` where a capturing separator's group did not match; this puts "".
  public func jsSplit(_ separator: JSRegex, limit: Int? = nil) -> [String] {
    let bound = Int(limit.map { UInt32(truncatingIfNeeded: $0) } ?? UInt32.max)
    guard bound > 0 else { return [] }
    let units = jsCodeUnits
    var machine = separator.machine(for: units)
    if units.isEmpty { return machine.match(at: 0) == nil ? [""] : [] }
    var pieces: [String] = []
    var pieceStart = 0
    var position = 0
    while position < units.count {
      guard let slots = machine.match(at: position), Swift.min(slots[1], units.count) != pieceStart else {
        position = machine.advance(position)
        continue
      }
      pieces.append(JSText.string(fromCodeUnits: units[pieceStart..<position]))
      if pieces.count == bound { return pieces }
      pieceStart = Swift.min(slots[1], units.count)
      for slot in stride(from: 2, to: slots.count, by: 2) {
        pieces.append(slots[slot] < 0 ? "" : JSText.string(fromCodeUnits: units[slots[slot]..<slots[slot + 1]]))
        if pieces.count == bound { return pieces }
      }
      position = pieceStart
    }
    pieces.append(JSText.string(fromCodeUnits: units[pieceStart...]))
    return pieces
  }

  private func replacing(_ pattern: JSRegex, _ replacement: ([Int], [UInt16]) -> [UInt16]) -> String {
    let units = jsCodeUnits
    let matches = pattern.global ? pattern.allMatchSlots(in: units) : pattern.firstMatchSlots(in: units, from: 0).map { [$0] } ?? []
    guard !matches.isEmpty else { return self }
    var result: [UInt16] = []
    var nextSource = 0
    for slots in matches where slots[0] >= nextSource {
      result.append(contentsOf: units[nextSource..<slots[0]])
      result.append(contentsOf: replacement(slots, units))
      nextSource = slots[1]
    }
    result.append(contentsOf: units[nextSource...])
    return JSText.string(fromCodeUnits: result)
  }

  /// GetSubstitution: a two-digit `$nn` beyond the group count reads as `$n` and a digit, and a reference to no group stays literal.
  private static func substitute(_ template: [UInt16], slots: [Int], units: [UInt16]) -> [UInt16] {
    let dollar = UInt16(ascii: "$")
    let groupCount = slots.count / 2 - 1
    var result: [UInt16] = []
    var index = 0
    while index < template.count {
      guard template[index] == dollar, index + 1 < template.count else {
        result.append(template[index])
        index += 1
        continue
      }
      let next = template[index + 1]
      switch next {
      case dollar:
        result.append(dollar)
        index += 2
      case UInt16(ascii: "&"):
        result.append(contentsOf: units[slots[0]..<slots[1]])
        index += 2
      case UInt16(ascii: "`"):
        result.append(contentsOf: units[0..<slots[0]])
        index += 2
      case UInt16(ascii: "'"):
        result.append(contentsOf: units[Swift.min(slots[1], units.count)...])
        index += 2
      case UInt16(ascii: "0")...UInt16(ascii: "9"):
        let first = Int(next - UInt16(ascii: "0"))
        var digitCount = 1
        var group = first
        if index + 2 < template.count, (UInt16(ascii: "0")...UInt16(ascii: "9")).contains(template[index + 2]) {
          let twoDigits = first * 10 + Int(template[index + 2] - UInt16(ascii: "0"))
          if twoDigits <= groupCount {
            digitCount = 2
            group = twoDigits
          }
        }
        if group >= 1, group <= groupCount {
          let start = slots[2 * group]
          if start >= 0 { result.append(contentsOf: units[start..<slots[2 * group + 1]]) }
        } else {
          result.append(contentsOf: template[index..<(index + 1 + digitCount)])
        }
        index += 1 + digitCount
      default:
        result.append(dollar)
        index += 1
      }
    }
    return result
  }
}

extension UInt16 {
  fileprivate init(ascii scalar: Unicode.Scalar) {
    self = UInt16(truncatingIfNeeded: scalar.value)
  }
}
