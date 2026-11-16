import Foundation

public enum CanonicalJSONError: ShadowError, Equatable {
  case invalidSyntax(offset: Int)
  case duplicateKey(offset: Int)
  case numberNotInt64(offset: Int)
  case invalidUTF8(offset: Int)
  case invalidEscape(offset: Int)
  case nestingTooDeep(offset: Int)
  case notCanonical

  public var code: String {
    switch self {
    case .invalidSyntax: "canonical_json.invalid_syntax"
    case .duplicateKey: "canonical_json.duplicate_key"
    case .numberNotInt64: "canonical_json.number_not_int64"
    case .invalidUTF8: "canonical_json.invalid_utf8"
    case .invalidEscape: "canonical_json.invalid_escape"
    case .nestingTooDeep: "canonical_json.nesting_too_deep"
    case .notCanonical: "canonical_json.not_canonical"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidSyntax(let offset): "Invalid JSON syntax at byte \(offset)."
    case .duplicateKey(let offset): "Duplicate object key at byte \(offset)."
    case .numberNotInt64(let offset): "Number at byte \(offset) is not an integer in the Int64 range."
    case .invalidUTF8(let offset): "Invalid UTF-8 in string at byte \(offset)."
    case .invalidEscape(let offset): "Invalid escape sequence at byte \(offset)."
    case .nestingTooDeep(let offset): "Nesting deeper than \(CanonicalJSON.maximumDepth) at byte \(offset)."
    case .notCanonical: "JSON text is valid but not in canonical form."
    }
  }
}

public enum CanonicalJSON {
  public static let maximumDepth = 64

  public enum DecodingMode: Sendable {
    case canonical
    case lenient
  }

  public static func encode(_ value: JSONValue) -> Data {
    var output = [UInt8]()
    write(value, to: &output)
    return Data(output)
  }

  public static func decode(_ data: Data, mode: DecodingMode = .canonical) throws(CanonicalJSONError) -> JSONValue {
    var parser = JSONParser(bytes: Array(data))
    let value = try parser.parseDocument()
    if mode == .canonical { guard encode(value) == data else { throw .notCanonical } }
    return value
  }
}

extension CanonicalJSON {
  private static let hexDigits = Array("0123456789abcdef".utf8)

  private static func write(_ value: JSONValue, to output: inout [UInt8]) {
    switch value {
    case .null:
      output.append(contentsOf: "null".utf8)
    case .bool(let flag):
      output.append(contentsOf: (flag ? "true" : "false").utf8)
    case .int(let number):
      output.append(contentsOf: String(number).utf8)
    case .string(let text):
      writeString(text, to: &output)
    case .array(let elements):
      output.append(UInt8(ascii: "["))
      for (index, element) in elements.enumerated() {
        if index > 0 { output.append(UInt8(ascii: ",")) }
        write(element, to: &output)
      }
      output.append(UInt8(ascii: "]"))
    case .object(let members):
      output.append(UInt8(ascii: "{"))
      for (index, member) in members.sorted(by: { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }).enumerated() {
        if index > 0 { output.append(UInt8(ascii: ",")) }
        writeString(member.key, to: &output)
        output.append(UInt8(ascii: ":"))
        write(member.value, to: &output)
      }
      output.append(UInt8(ascii: "}"))
    }
  }

  private static func writeString(_ text: String, to output: inout [UInt8]) {
    output.append(UInt8(ascii: "\""))
    for byte in text.utf8 {
      switch byte {
      case UInt8(ascii: "\""): output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
      case UInt8(ascii: "\\"): output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
      case 0x08: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
      case 0x09: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
      case 0x0A: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
      case 0x0C: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
      case 0x0D: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
      case 0x00..<0x20:
        output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]])
      default: output.append(byte)
      }
    }
    output.append(UInt8(ascii: "\""))
  }
}

private struct JSONParser {
  let bytes: [UInt8]
  var index = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  mutating func parseDocument() throws(CanonicalJSONError) -> JSONValue {
    skipWhitespace()
    let value = try parseValue(depth: 0)
    skipWhitespace()
    guard index == bytes.count else { throw .invalidSyntax(offset: index) }
    return value
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D { index += 1 }
  }

  private mutating func parseValue(depth: Int) throws(CanonicalJSONError) -> JSONValue {
    guard index < bytes.count else { throw .invalidSyntax(offset: index) }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try parseObject(depth: depth + 1)
    case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"):
      try expect("true")
      return .bool(true)
    case UInt8(ascii: "f"):
      try expect("false")
      return .bool(false)
    case UInt8(ascii: "n"):
      try expect("null")
      return .null
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .int(try parseInteger())
    default: throw .invalidSyntax(offset: index)
    }
  }

  private mutating func expect(_ literal: StaticString) throws(CanonicalJSONError) {
    let expected = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
    guard index + expected.count <= bytes.count, bytes[index..<index + expected.count].elementsEqual(expected) else { throw .invalidSyntax(offset: index) }
    index += expected.count
  }

  private mutating func parseArray(depth: Int) throws(CanonicalJSONError) -> JSONValue {
    guard depth <= CanonicalJSON.maximumDepth else { throw .nestingTooDeep(offset: index) }
    index += 1
    var elements = [JSONValue]()
    skipWhitespace()
    if try consume(UInt8(ascii: "]")) { return .array(elements) }
    while true {
      skipWhitespace()
      elements.append(try parseValue(depth: depth))
      skipWhitespace()
      if try consume(UInt8(ascii: "]")) { return .array(elements) }
      guard try consume(UInt8(ascii: ",")) else { throw .invalidSyntax(offset: index) }
    }
  }

  private mutating func parseObject(depth: Int) throws(CanonicalJSONError) -> JSONValue {
    guard depth <= CanonicalJSON.maximumDepth else { throw .nestingTooDeep(offset: index) }
    index += 1
    var members = [String: JSONValue]()
    skipWhitespace()
    if try consume(UInt8(ascii: "}")) { return .object(members) }
    while true {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw .invalidSyntax(offset: index) }
      let keyOffset = index
      let key = try parseString()
      skipWhitespace()
      guard try consume(UInt8(ascii: ":")) else { throw .invalidSyntax(offset: index) }
      skipWhitespace()
      let value = try parseValue(depth: depth)
      guard members.updateValue(value, forKey: key) == nil else { throw .duplicateKey(offset: keyOffset) }
      skipWhitespace()
      if try consume(UInt8(ascii: "}")) { return .object(members) }
      guard try consume(UInt8(ascii: ",")) else { throw .invalidSyntax(offset: index) }
    }
  }

  private mutating func consume(_ byte: UInt8) throws(CanonicalJSONError) -> Bool {
    guard index < bytes.count else { throw .invalidSyntax(offset: index) }
    guard bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private mutating func parseInteger() throws(CanonicalJSONError) -> Int64 {
    let start = index
    let negative = bytes[index] == UInt8(ascii: "-")
    if negative { index += 1 }
    guard index < bytes.count, isDigit(bytes[index]) else { throw .invalidSyntax(offset: index) }
    let firstDigit = bytes[index]
    var magnitude: UInt64 = 0
    var overflow = false
    while index < bytes.count, isDigit(bytes[index]) {
      if index > start + (negative ? 1 : 0), firstDigit == UInt8(ascii: "0") { throw .invalidSyntax(offset: index) }
      let (scaled, scaleOverflow) = magnitude.multipliedReportingOverflow(by: 10)
      let (sum, addOverflow) = scaled.addingReportingOverflow(UInt64(bytes[index] - UInt8(ascii: "0")))
      overflow = overflow || scaleOverflow || addOverflow
      magnitude = sum
      index += 1
    }
    if index < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) { throw .numberNotInt64(offset: start) }
    guard !overflow else { throw .numberNotInt64(offset: start) }
    if negative {
      guard magnitude != 0, magnitude <= UInt64(Int64.max) + 1 else { throw .numberNotInt64(offset: start) }
      return Int64(truncatingIfNeeded: 0 &- magnitude)
    }
    guard magnitude <= UInt64(Int64.max) else { throw .numberNotInt64(offset: start) }
    return Int64(magnitude)
  }

  private func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }

  private mutating func parseString() throws(CanonicalJSONError) -> String {
    let start = index
    index += 1
    var buffer = [UInt8]()
    while true {
      guard index < bytes.count else { throw .invalidSyntax(offset: index) }
      let byte = bytes[index]
      switch byte {
      case UInt8(ascii: "\""):
        index += 1
        guard let text = String(validating: buffer, as: UTF8.self) else { throw .invalidUTF8(offset: start) }
        return text
      case UInt8(ascii: "\\"):
        try parseEscape(into: &buffer)
      case 0x00..<0x20:
        throw .invalidSyntax(offset: index)
      default:
        buffer.append(byte)
        index += 1
      }
    }
  }

  private mutating func parseEscape(into buffer: inout [UInt8]) throws(CanonicalJSONError) {
    let offset = index
    guard index + 1 < bytes.count else { throw .invalidSyntax(offset: bytes.count) }
    index += 2
    switch bytes[index - 1] {
    case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
    case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
    case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
    case UInt8(ascii: "b"): buffer.append(0x08)
    case UInt8(ascii: "f"): buffer.append(0x0C)
    case UInt8(ascii: "n"): buffer.append(0x0A)
    case UInt8(ascii: "r"): buffer.append(0x0D)
    case UInt8(ascii: "t"): buffer.append(0x09)
    case UInt8(ascii: "u"):
      let unit = try parseHexUnit(escapeOffset: offset)
      var scalarValue = UInt32(unit)
      if (0xDC00...0xDFFF).contains(unit) { throw .invalidEscape(offset: offset) }
      if (0xD800...0xDBFF).contains(unit) {
        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw .invalidEscape(offset: offset) }
        index += 2
        let low = try parseHexUnit(escapeOffset: offset)
        guard (0xDC00...0xDFFF).contains(low) else { throw .invalidEscape(offset: offset) }
        scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
      }
      guard let scalar = Unicode.Scalar(scalarValue) else { throw .invalidEscape(offset: offset) }
      UTF8.encode(scalar) { buffer.append($0) }
    default:
      throw .invalidEscape(offset: offset)
    }
  }

  private mutating func parseHexUnit(escapeOffset: Int) throws(CanonicalJSONError) -> UInt16 {
    guard index + 4 <= bytes.count else { throw .invalidEscape(offset: escapeOffset) }
    var unit: UInt16 = 0
    for byte in bytes[index..<index + 4] {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): unit = unit << 4 | UInt16(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): unit = unit << 4 | UInt16(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): unit = unit << 4 | UInt16(byte - UInt8(ascii: "A") + 10)
      default: throw .invalidEscape(offset: escapeOffset)
      }
    }
    index += 4
    return unit
  }
}
