/// The pattern's need at the start of a match as one bit per code unit: a search skips any other start without running the matcher.
struct JSRegexFirstUnits: Sendable {
  private let words: [UInt64]
  let admitsEnd: Bool

  init?(_ need: JSRegexNeed) {
    guard need != .anything else { return nil }
    var words = Array(repeating: need.others == nil ? ~UInt64(0) : 0, count: 1024)
    words[0] = need.asciiLow
    words[1] = need.asciiHigh
    for unit in need.others ?? [] { words[Int(unit >> 6)] |= 1 << UInt64(unit & 63) }
    self.words = words
    admitsEnd = need.boundary
  }

  func admits(_ units: [UInt16], at position: Int) -> Bool {
    guard position < units.count else { return admitsEnd }
    let unit = units[position]
    return words[Int(unit >> 6)] >> UInt64(unit & 63) & 1 == 1
  }

  /// The first start at or after `start` that the need admits, `units.count` when only the end is left, or past it when not even the end is.
  func next(in units: [UInt16], from start: Int, unicode: Bool) -> Int {
    var index = start
    while index < units.count {
      let unit = units[index]
      if words[Int(unit >> 6)] >> UInt64(unit & 63) & 1 == 1 { return index }
      index += unicode && unit & 0xFC00 == 0xD800 && index + 1 < units.count && units[index + 1] & 0xFC00 == 0xDC00 ? 2 : 1
    }
    return admitsEnd ? index : index + 1
  }
}
