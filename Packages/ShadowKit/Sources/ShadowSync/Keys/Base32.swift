import Foundation

enum Base32 {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

  static func encode(_ bytes: some Sequence<UInt8>) -> String {
    var output: [UInt8] = []
    var buffer: UInt32 = 0
    var bitCount = 0
    for byte in bytes {
      buffer = (buffer << 8) | UInt32(byte)
      bitCount += 8
      while bitCount >= 5 {
        bitCount -= 5
        output.append(alphabet[Int((buffer >> UInt32(bitCount)) & 0x1F)])
      }
      buffer &= (1 << UInt32(bitCount)) - 1
    }
    if bitCount > 0 { output.append(alphabet[Int((buffer << UInt32(5 - bitCount)) & 0x1F)]) }
    return String(decoding: output, as: UTF8.self)
  }

  static func decode(_ text: some Collection<UInt8>) -> [UInt8]? {
    let characters = Array(text)
    guard ![1, 3, 6].contains(characters.count % 8) else { return nil }
    var output: [UInt8] = []
    output.reserveCapacity(characters.count * 5 / 8)
    var buffer: UInt32 = 0
    var bitCount = 0
    for character in characters {
      guard let value = value(of: character) else { return nil }
      buffer = (buffer << 5) | UInt32(value)
      bitCount += 5
      if bitCount >= 8 {
        bitCount -= 8
        output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bitCount)))
        buffer &= (1 << UInt32(bitCount)) - 1
      }
    }
    guard buffer == 0 else { return nil }
    return output
  }

  private static func value(of character: UInt8) -> UInt8? {
    switch character {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): character - UInt8(ascii: "A")
    case UInt8(ascii: "2")...UInt8(ascii: "7"): character - UInt8(ascii: "2") + 26
    default: nil
    }
  }
}
