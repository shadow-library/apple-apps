import Foundation
import ShadowCore

struct ChangeSetElement: Equatable, Sendable {
  /// Exact JSON text; a raw lone surrogate in it is replaced by U+FFFD because a Swift string cannot hold one.
  let source: String
  let op: String
  private let integersOnly: Bool

  init?(source: String) {
    self.init(units: Array(source.utf16))
  }

  init?(units: [UInt16]) {
    guard let inspection = ElementSyntax.inspect(units) else { return nil }
    source = String(decoding: units, as: UTF16.self)
    op = String(decoding: inspection.op, as: UTF16.self)
    integersOnly = inspection.integersOnly
  }

  /// Nil when any number is not an Int64 integer (fraction, exponent, out of range), an escape names a lone surrogate, or nesting exceeds the decoder's depth limit.
  var jsonValue: JSONValue? {
    guard integersOnly else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
  }
}

private struct ElementInspection {
  let op: [UInt16]
  let integersOnly: Bool
}

private enum ElementSyntax {
  private enum Container {
    case object
    case array
  }

  private enum Expect {
    case value
    case afterValue
  }

  static func inspect(_ units: [UInt16]) -> ElementInspection? {
    var cursor = Cursor(units: units)
    var stack: [Container] = []
    var expect = Expect.value
    var op: [UInt16]?
    var opKeyPending = false
    var integersOnly = true
    var scratch: [UInt16] = []

    while true {
      switch expect {
      case .value:
        cursor.skipWhitespace()
        guard let unit = cursor.peek else { return nil }
        let isOpValue = stack.count == 1 && opKeyPending
        opKeyPending = false
        if isOpValue { op = nil }
        switch unit {
        case JSONCodeUnit.openBrace:
          cursor.advance()
          stack.append(.object)
          cursor.skipWhitespace()
          if cursor.peek == JSONCodeUnit.closeBrace {
            cursor.advance()
            stack.removeLast()
            expect = .afterValue
          } else {
            guard readKey(&cursor, atTopLevel: stack.count == 1, scratch: &scratch, opKeyPending: &opKeyPending) else { return nil }
          }
        case JSONCodeUnit.openBracket:
          cursor.advance()
          stack.append(.array)
          cursor.skipWhitespace()
          if cursor.peek == JSONCodeUnit.closeBracket {
            cursor.advance()
            stack.removeLast()
            expect = .afterValue
          }
        case JSONCodeUnit.quote:
          scratch.removeAll(keepingCapacity: true)
          guard cursor.skipString(into: &scratch, capture: isOpValue) else { return nil }
          if isOpValue { op = scratch }
          expect = .afterValue
        default:
          guard cursor.skipLiteralOrNumber(integersOnly: &integersOnly) else { return nil }
          expect = .afterValue
        }
      case .afterValue:
        guard let container = stack.last else {
          cursor.skipWhitespace()
          guard cursor.peek == nil, let op else { return nil }
          return ElementInspection(op: op, integersOnly: integersOnly)
        }
        cursor.skipWhitespace()
        guard let unit = cursor.peek else { return nil }
        cursor.advance()
        switch (container, unit) {
        case (.object, JSONCodeUnit.comma):
          cursor.skipWhitespace()
          guard readKey(&cursor, atTopLevel: stack.count == 1, scratch: &scratch, opKeyPending: &opKeyPending) else { return nil }
          expect = .value
        case (.object, JSONCodeUnit.closeBrace), (.array, JSONCodeUnit.closeBracket):
          stack.removeLast()
        case (.array, JSONCodeUnit.comma):
          expect = .value
        default:
          return nil
        }
      }
    }
  }

  private static func readKey(_ cursor: inout Cursor, atTopLevel: Bool, scratch: inout [UInt16], opKeyPending: inout Bool) -> Bool {
    guard cursor.peek == JSONCodeUnit.quote else { return false }
    scratch.removeAll(keepingCapacity: true)
    guard cursor.skipString(into: &scratch, capture: atTopLevel) else { return false }
    cursor.skipWhitespace()
    guard cursor.peek == JSONCodeUnit.colon else { return false }
    cursor.advance()
    opKeyPending = atTopLevel && scratch == JSONCodeUnit.opKey
    return true
  }
}

private struct Cursor {
  let units: [UInt16]
  var index = 0

  init(units: [UInt16]) {
    self.units = units
  }

  var peek: UInt16? { index < units.count ? units[index] : nil }

  mutating func advance() {
    index += 1
  }

  mutating func skipWhitespace() {
    while let unit = peek, unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D { index += 1 }
  }

  mutating func skipString(into buffer: inout [UInt16], capture: Bool) -> Bool {
    index += 1
    while let unit = peek {
      index += 1
      if unit == JSONCodeUnit.quote { return true }
      if unit < 0x20 { return false }
      guard unit == JSONCodeUnit.backslash else {
        if capture { buffer.append(unit) }
        continue
      }
      guard let escape = peek else { return false }
      index += 1
      if escape == JSONCodeUnit.lowerU {
        guard let code = readHex4() else { return false }
        if capture { buffer.append(code) }
        continue
      }
      guard let decoded = JSONCodeUnit.simpleEscapes[escape] else { return false }
      if capture { buffer.append(decoded) }
    }
    return false
  }

  private mutating func readHex4() -> UInt16? {
    var value: UInt16 = 0
    for _ in 0..<4 {
      guard let unit = peek, let digit = JSONCodeUnit.hexValue(unit) else { return nil }
      index += 1
      value = value << 4 | digit
    }
    return value
  }

  mutating func skipLiteralOrNumber(integersOnly: inout Bool) -> Bool {
    guard let unit = peek else { return false }
    switch unit {
    case JSONCodeUnit.lowerT: return skipWord(JSONCodeUnit.trueWord)
    case JSONCodeUnit.lowerF: return skipWord(JSONCodeUnit.falseWord)
    case JSONCodeUnit.lowerN: return skipWord(JSONCodeUnit.nullWord)
    default: return skipNumber(integersOnly: &integersOnly)
    }
  }

  private mutating func skipWord(_ word: [UInt16]) -> Bool {
    guard index + word.count <= units.count, units[index..<index + word.count].elementsEqual(word) else { return false }
    index += word.count
    return true
  }

  private mutating func skipNumber(integersOnly: inout Bool) -> Bool {
    var negative = false
    if peek == JSONCodeUnit.minus {
      negative = true
      index += 1
    }
    guard let first = peek, JSONCodeUnit.isDigit(first) else { return false }
    var magnitude: UInt64 = 0
    var overflow = false
    if first == JSONCodeUnit.zero {
      index += 1
    } else {
      while let unit = peek, JSONCodeUnit.isDigit(unit) {
        index += 1
        let (scaled, scaleOverflow) = magnitude.multipliedReportingOverflow(by: 10)
        let (sum, addOverflow) = scaled.addingReportingOverflow(UInt64(unit - JSONCodeUnit.zero))
        overflow = overflow || scaleOverflow || addOverflow
        magnitude = sum
      }
    }
    var isInteger = true
    if peek == JSONCodeUnit.dot {
      isInteger = false
      index += 1
      guard consumeDigits() else { return false }
    }
    if peek == JSONCodeUnit.lowerE || peek == JSONCodeUnit.upperE {
      isInteger = false
      index += 1
      if peek == JSONCodeUnit.plus || peek == JSONCodeUnit.minus { index += 1 }
      guard consumeDigits() else { return false }
    }
    let limit: UInt64 = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
    if !isInteger || overflow || magnitude > limit { integersOnly = false }
    return true
  }

  private mutating func consumeDigits() -> Bool {
    let start = index
    while let unit = peek, JSONCodeUnit.isDigit(unit) { index += 1 }
    return index > start
  }
}
