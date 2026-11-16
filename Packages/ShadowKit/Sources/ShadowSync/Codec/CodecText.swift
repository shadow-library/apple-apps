enum CodecText {
  static let dash = UInt8(ascii: "-")

  static func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }

  static func isLowerHexDigit(_ byte: UInt8) -> Bool {
    isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
  }

  static func isLowerHex(_ text: String, count: Int) -> Bool {
    text.utf8.count == count && text.utf8.allSatisfy(isLowerHexDigit)
  }

  static func decimal(_ bytes: ArraySlice<UInt8>) -> Int64? {
    guard !bytes.isEmpty, bytes.count <= 18, bytes.allSatisfy(isDigit) else { return nil }
    return bytes.reduce(Int64(0)) { $0 * 10 + Int64($1 - UInt8(ascii: "0")) }
  }

  static func padded(_ value: some BinaryInteger, width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }
}
