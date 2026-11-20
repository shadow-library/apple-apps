/// A match with UTF-16 offsets; texts that would hold half a surrogate pair drop it, as `JSText.string(fromCodeUnits:)` does.
public struct JSRegexMatch: Sendable, Equatable {
  public let index: Int
  /// `match[0].length`, counted on the code units matched, so it stays exact when `text` dropped a lone surrogate.
  public let length: Int
  public let text: String
  /// `match[1...]`, nil where JavaScript has `undefined`.
  public let groups: [String?]

  public var endIndex: Int { index + length }

  init(slots: [Int], units: [UInt16]) {
    index = slots[0]
    length = slots[1] - slots[0]
    text = JSText.string(fromCodeUnits: units[slots[0]..<slots[1]])
    groups = stride(from: 2, to: slots.count, by: 2).map { slot in
      let start = slots[slot]
      let end = slots[slot + 1]
      guard start >= 0, start <= end else { return nil }
      return JSText.string(fromCodeUnits: units[start..<end])
    }
  }
}

/// A `RegExp` object's `lastIndex`, for the call sites that call `exec` or `test` on one global expression repeatedly.
public struct JSRegexCursor: Sendable {
  let regex: JSRegex
  public var lastIndex = 0

  public init(_ regex: JSRegex) {
    self.regex = regex
  }

  /// A non-global expression ignores and keeps `lastIndex`; a global one starts there, moves it past the match and resets it to 0 on a miss.
  public mutating func exec(_ text: String) -> JSRegexMatch? {
    let units = text.jsCodeUnits
    guard regex.global else { return regex.firstMatchSlots(in: units, from: 0).map { JSRegexMatch(slots: $0, units: units) } }
    guard lastIndex <= units.count, let slots = regex.firstMatchSlots(in: units, from: lastIndex) else {
      lastIndex = 0
      return nil
    }
    lastIndex = slots[1]
    return JSRegexMatch(slots: slots, units: units)
  }

  public mutating func test(_ text: String) -> Bool {
    exec(text) != nil
  }
}
