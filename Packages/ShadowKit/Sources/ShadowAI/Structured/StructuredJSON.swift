/// An exact JSON number: `significand × 10^exponent`, normalised so that equal values compare equal however they were written.
struct StructuredJSONNumber: Sendable, Equatable, Comparable {
  private static let exponentBound = 1_000_000_000_000

  let isNegative: Bool
  let significand: [UInt8]
  let exponent: Int

  var isZero: Bool { significand.isEmpty }

  var isInteger: Bool { isZero || exponent >= 0 }

  init(isNegative: Bool, digits: some Collection<UInt8>, exponent: Int) {
    var digits = Array(digits.drop(while: { $0 == 0 }))
    var exponent = exponent
    while let last = digits.last, last == 0 {
      digits.removeLast()
      exponent = Self.clamped(exponent + 1)
    }
    self.isNegative = isNegative && !digits.isEmpty
    self.significand = digits
    self.exponent = digits.isEmpty ? 0 : exponent
  }

  init(_ value: Int64) {
    var digits: [UInt8] = []
    var magnitude = value.magnitude
    repeat {
      digits.append(UInt8(magnitude % 10))
      magnitude /= 10
    } while magnitude > 0
    self.init(isNegative: value < 0, digits: digits.reversed(), exponent: 0)
  }

  static func clamped(_ exponent: Int) -> Int {
    min(max(exponent, -exponentBound), exponentBound)
  }

  static func < (lhs: StructuredJSONNumber, rhs: StructuredJSONNumber) -> Bool {
    if lhs.sign != rhs.sign { return lhs.sign < rhs.sign }
    guard lhs.sign != 0 else { return false }
    return lhs.isNegative ? rhs.magnitudeIsLess(than: lhs) : lhs.magnitudeIsLess(than: rhs)
  }

  private var sign: Int {
    if isZero { return 0 }
    return isNegative ? -1 : 1
  }

  private var order: Int { significand.count + exponent }

  private func magnitudeIsLess(than other: StructuredJSONNumber) -> Bool {
    if order != other.order { return order < other.order }
    for (mine, theirs) in zip(significand, other.significand) where mine != theirs { return mine < theirs }
    return significand.count < other.significand.count
  }
}

enum StructuredJSONNode: Sendable {
  case null
  case bool(Bool)
  case number(StructuredJSONNumber)
  case string(String)
  case array([StructuredJSONValue])
  case object([StructuredJSONMember])
}

struct StructuredJSONValue: Sendable {
  let node: StructuredJSONNode
  /// Byte offsets of the value in the text it was parsed from.
  let range: Range<Int>
}

struct StructuredJSONMember: Sendable {
  let key: String
  let value: StructuredJSONValue
}

struct StructuredJSONSyntaxError: Error, Sendable, Equatable {
  let offset: Int
  let reason: String
}

/// Strict RFC 8259 JSON that keeps decimals exactly, keeps duplicate keys for the validator to report, and refuses lone surrogates as `JSONDecoder` does.
struct StructuredJSONParser {
  static let maximumDepth = 64

  private let bytes: [UInt8]
  private let end: Int
  private var index: Int

  static func parse(_ bytes: [UInt8], in range: Range<Int>? = nil) throws(StructuredJSONSyntaxError) -> StructuredJSONValue {
    let range = range ?? bytes.indices
    var parser = StructuredJSONParser(bytes: bytes, start: range.lowerBound, end: range.upperBound)
    parser.skipWhitespace()
    let value = try parser.parseValue(depth: 0)
    parser.skipWhitespace()
    guard parser.index == parser.end else { throw parser.failure("unexpected text after the JSON value") }
    return value
  }

  static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }

  private init(bytes: [UInt8], start: Int, end: Int) {
    self.bytes = bytes
    self.index = start
    self.end = end
  }

  private func failure(_ reason: String) -> StructuredJSONSyntaxError {
    StructuredJSONSyntaxError(offset: index, reason: reason)
  }

  private var current: UInt8? { index < end ? bytes[index] : nil }

  private mutating func skipWhitespace() {
    while let byte = current, Self.isWhitespace(byte) { index += 1 }
  }

  private mutating func parseValue(depth: Int) throws(StructuredJSONSyntaxError) -> StructuredJSONValue {
    let start = index
    guard let byte = current else { throw failure("the text ends where a value should be") }
    let node: StructuredJSONNode
    switch byte {
    case UInt8(ascii: "{"): node = try parseObject(depth: depth + 1)
    case UInt8(ascii: "["): node = try parseArray(depth: depth + 1)
    case UInt8(ascii: "\""): node = .string(try parseString())
    case UInt8(ascii: "t"):
      try expect("true")
      node = .bool(true)
    case UInt8(ascii: "f"):
      try expect("false")
      node = .bool(false)
    case UInt8(ascii: "n"):
      try expect("null")
      node = .null
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): node = .number(try parseNumber())
    default: throw failure("expected a JSON value")
    }
    return StructuredJSONValue(node: node, range: start..<index)
  }

  private mutating func expect(_ literal: String) throws(StructuredJSONSyntaxError) {
    for expected in literal.utf8 {
      guard current == expected else { throw failure("expected \(literal)") }
      index += 1
    }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard current == byte else { return false }
    index += 1
    return true
  }

  private mutating func parseArray(depth: Int) throws(StructuredJSONSyntaxError) -> StructuredJSONNode {
    guard depth <= Self.maximumDepth else { throw failure("nesting deeper than \(Self.maximumDepth) levels") }
    index += 1
    var elements: [StructuredJSONValue] = []
    skipWhitespace()
    if consume(UInt8(ascii: "]")) { return .array(elements) }
    while true {
      skipWhitespace()
      elements.append(try parseValue(depth: depth))
      skipWhitespace()
      if consume(UInt8(ascii: "]")) { return .array(elements) }
      guard consume(UInt8(ascii: ",")) else { throw failure("expected , or ] in an array") }
    }
  }

  private mutating func parseObject(depth: Int) throws(StructuredJSONSyntaxError) -> StructuredJSONNode {
    guard depth <= Self.maximumDepth else { throw failure("nesting deeper than \(Self.maximumDepth) levels") }
    index += 1
    var members: [StructuredJSONMember] = []
    skipWhitespace()
    if consume(UInt8(ascii: "}")) { return .object(members) }
    while true {
      skipWhitespace()
      guard current == UInt8(ascii: "\"") else { throw failure("expected a quoted property name") }
      let key = try parseString()
      skipWhitespace()
      guard consume(UInt8(ascii: ":")) else { throw failure("expected : after a property name") }
      skipWhitespace()
      members.append(StructuredJSONMember(key: key, value: try parseValue(depth: depth)))
      skipWhitespace()
      if consume(UInt8(ascii: "}")) { return .object(members) }
      guard consume(UInt8(ascii: ",")) else { throw failure("expected , or } in an object") }
    }
  }

  private mutating func parseNumber() throws(StructuredJSONSyntaxError) -> StructuredJSONNumber {
    let isNegative = consume(UInt8(ascii: "-"))
    var digits: [UInt8] = []
    guard let first = current, Self.isDigit(first) else { throw failure("expected a digit") }
    if first == UInt8(ascii: "0") {
      index += 1
      if let next = current, Self.isDigit(next) { throw failure("a number cannot have a leading zero") }
    } else {
      while let byte = current, Self.isDigit(byte) {
        digits.append(byte - UInt8(ascii: "0"))
        index += 1
      }
    }
    var fractionDigits = 0
    if consume(UInt8(ascii: ".")) {
      guard let byte = current, Self.isDigit(byte) else { throw failure("expected a digit after the decimal point") }
      while let byte = current, Self.isDigit(byte) {
        digits.append(byte - UInt8(ascii: "0"))
        fractionDigits += 1
        index += 1
      }
    }
    var exponent = 0
    if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
      let negativeExponent = consume(UInt8(ascii: "-"))
      if !negativeExponent { _ = consume(UInt8(ascii: "+")) }
      guard let byte = current, Self.isDigit(byte) else { throw failure("expected a digit in the exponent") }
      while let byte = current, Self.isDigit(byte) {
        exponent = StructuredJSONNumber.clamped(exponent * 10 + Int(byte - UInt8(ascii: "0")))
        index += 1
      }
      if negativeExponent { exponent = -exponent }
    }
    return StructuredJSONNumber(isNegative: isNegative, digits: digits, exponent: StructuredJSONNumber.clamped(exponent - fractionDigits))
  }

  private static func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }

  private mutating func parseString() throws(StructuredJSONSyntaxError) -> String {
    index += 1
    var buffer: [UInt8] = []
    while true {
      guard let byte = current else { throw failure("the text ends inside a string") }
      switch byte {
      case UInt8(ascii: "\""):
        guard let text = String(validating: buffer, as: UTF8.self) else { throw failure("a string is not valid UTF-8") }
        index += 1
        return text
      case UInt8(ascii: "\\"):
        try parseEscape(into: &buffer)
      case 0x00..<0x20:
        throw failure("a string contains an unescaped control character")
      default:
        buffer.append(byte)
        index += 1
      }
    }
  }

  private mutating func parseEscape(into buffer: inout [UInt8]) throws(StructuredJSONSyntaxError) {
    index += 1
    guard let escaped = current else { throw failure("the text ends inside an escape") }
    index += 1
    switch escaped {
    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(escaped)
    case UInt8(ascii: "b"): buffer.append(0x08)
    case UInt8(ascii: "f"): buffer.append(0x0C)
    case UInt8(ascii: "n"): buffer.append(0x0A)
    case UInt8(ascii: "r"): buffer.append(0x0D)
    case UInt8(ascii: "t"): buffer.append(0x09)
    case UInt8(ascii: "u"):
      let unit = try parseHexUnit()
      var value = UInt32(unit)
      if (0xDC00...0xDFFF).contains(unit) { throw failure("a \\u escape is a lone low surrogate") }
      if (0xD800...0xDBFF).contains(unit) {
        guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else { throw failure("a \\u escape is a lone high surrogate") }
        let low = try parseHexUnit()
        guard (0xDC00...0xDFFF).contains(low) else { throw failure("a \\u escape is a lone high surrogate") }
        value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
      }
      guard let scalar = Unicode.Scalar(value) else { throw failure("a \\u escape is not a Unicode scalar") }
      UTF8.encode(scalar) { buffer.append($0) }
    default:
      throw failure("an unknown escape sequence")
    }
  }

  private mutating func parseHexUnit() throws(StructuredJSONSyntaxError) -> UInt16 {
    var unit: UInt16 = 0
    for _ in 0..<4 {
      guard let byte = current else { throw failure("the text ends inside a \\u escape") }
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): unit = unit << 4 | UInt16(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): unit = unit << 4 | UInt16(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): unit = unit << 4 | UInt16(byte - UInt8(ascii: "A") + 10)
      default: throw failure("a \\u escape needs four hex digits")
      }
      index += 1
    }
    return unit
  }
}
