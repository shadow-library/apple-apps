import Foundation

enum OpenRouterDecimal {
  private static let exponentCap = 1_000_000
  private static let int64Digits = 19

  static func scaledNonNegative(_ text: String, byPowerOfTen power: Int) -> Int64? {
    guard let number = Number(text) else { return nil }
    guard let first = number.digits.firstIndex(where: { $0 != 0 }) else { return 0 }
    guard !number.isNegative else { return nil }
    let significant = number.digits[first...]
    let shift = power + number.exponent - number.fractionDigits
    if shift >= 0 {
      guard significant.count + shift <= int64Digits else { return nil }
      return accumulate(significant, trailingZeros: shift)
    }
    let kept = significant.count + shift
    guard kept >= 0 else { return 0 }
    let integer = significant.prefix(kept)
    guard let truncated = accumulate(integer, trailingZeros: 0) else { return nil }
    guard significant[significant.startIndex + kept] >= 5 else { return truncated }
    let (rounded, overflow) = truncated.addingReportingOverflow(1)
    return overflow ? nil : rounded
  }

  private static func accumulate(_ digits: some Collection<UInt8>, trailingZeros: Int) -> Int64? {
    var value: Int64 = 0
    for digit in Array(digits) + repeatElement(0, count: trailingZeros) {
      let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: 10)
      let (added, addOverflow) = shifted.addingReportingOverflow(Int64(digit))
      guard !shiftOverflow, !addOverflow else { return nil }
      value = added
    }
    return value
  }

  private struct Number {
    var isNegative = false
    var digits: [UInt8] = []
    var fractionDigits = 0
    var exponent = 0

    init?(_ text: String) {
      let bytes = Array(text.trimmingCharacters(in: .whitespaces).utf8)
      var index = bytes.startIndex
      if index < bytes.endIndex, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
        isNegative = bytes[index] == UInt8(ascii: "-")
        index += 1
      }
      var sawPoint = false
      while index < bytes.endIndex {
        let byte = bytes[index]
        if let digit = Self.digit(byte) {
          digits.append(digit)
          if sawPoint { fractionDigits += 1 }
        } else if byte == UInt8(ascii: "."), !sawPoint {
          sawPoint = true
        } else {
          break
        }
        index += 1
      }
      guard !digits.isEmpty else { return nil }
      if index < bytes.endIndex, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
        index += 1
        var exponentIsNegative = false
        if index < bytes.endIndex, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
          exponentIsNegative = bytes[index] == UInt8(ascii: "-")
          index += 1
        }
        let start = index
        while index < bytes.endIndex, let digit = Self.digit(bytes[index]) {
          exponent = min(exponent * 10 + Int(digit), OpenRouterDecimal.exponentCap)
          index += 1
        }
        guard index > start else { return nil }
        if exponentIsNegative { exponent = -exponent }
      }
      guard index == bytes.endIndex else { return nil }
    }

    private static func digit(_ byte: UInt8) -> UInt8? {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ? byte - UInt8(ascii: "0") : nil
    }
  }
}

struct OpenRouterAmount: Decodable, Sendable, Equatable {
  let text: String?

  init(text: String?) {
    self.text = text
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self) {
      text = string
    } else if let decimal = try? container.decode(Decimal.self) {
      text = decimal.description
    } else {
      text = nil
    }
  }

  var nanoUSD: Cost? {
    text.flatMap { OpenRouterDecimal.scaledNonNegative($0, byPowerOfTen: 9) }.map(Cost.init(nanoUSD:))
  }

  /// OpenRouter publishes prices in USD per token.
  var perMillionTokens: Cost? {
    text.flatMap { OpenRouterDecimal.scaledNonNegative($0, byPowerOfTen: 15) }.map(Cost.init(nanoUSD:))
  }
}
