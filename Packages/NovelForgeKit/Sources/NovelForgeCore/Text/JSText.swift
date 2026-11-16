enum JSText {
  /// Drops the dangling half wherever JavaScript would produce a lone surrogate, which no Swift string can hold.
  static func string<Units: Sequence<UInt16>>(fromCodeUnits units: Units) -> String {
    var scalars = String.UnicodeScalarView()
    var iterator = units.makeIterator()
    var decoder = UTF16()
    while true {
      switch decoder.decode(&iterator) {
      case .scalarValue(let scalar): scalars.append(scalar)
      case .error: continue
      case .emptyInput: return String(scalars)
      }
    }
  }

  /// Unlike `Character.isWhitespace`, the ECMAScript set holds U+FEFF and leaves out U+0085, U+180E and U+200B.
  static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x2028, 0x2029, 0xFEFF: true
    default: scalar.properties.generalCategory == .spaceSeparator
    }
  }

  /// Unlike `<`, places astral characters before U+E000–U+FFFF and never equates canonically equivalent strings.
  static func codeUnitPrecedes(_ left: String, _ right: String) -> Bool {
    left.utf16.lexicographicallyPrecedes(right.utf16)
  }

  /// Array indices ascending, then the other keys as inserted.
  static func ownPropertyKeyOrder(_ insertionOrder: [String]) -> [String] {
    let indexed = insertionOrder.compactMap { key in arrayIndex(key).map { (index: $0, key: key) } }
    return indexed.sorted { $0.index < $1.index }.map(\.key) + insertionOrder.filter { arrayIndex($0) == nil }
  }

  static func arrayIndex(_ key: String) -> UInt32? {
    let digits = Array(key.utf8)
    guard let first = digits.first, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
    if first == 0x30 { return digits.count == 1 ? 0 : nil }
    guard digits.count <= 10, let value = UInt64(key), value < UInt64(UInt32.max) else { return nil }
    return UInt32(value)
  }

  static func relativeIndex(_ index: Int, length: Int) -> Int {
    index < 0 ? max(length + index, 0) : min(index, length)
  }

  static func clamped(_ index: Int, length: Int) -> Int {
    min(max(index, 0), length)
  }

  static func indexOf(_ needle: [UInt16], in haystack: [UInt16], from start: Int) -> Int {
    guard start <= haystack.count else { return -1 }
    guard !needle.isEmpty else { return start }
    guard needle.count <= haystack.count - start else { return -1 }
    for candidate in start...(haystack.count - needle.count) where haystack[candidate] == needle[0] {
      if haystack[candidate..<(candidate + needle.count)].elementsEqual(needle) { return candidate }
    }
    return -1
  }
}
