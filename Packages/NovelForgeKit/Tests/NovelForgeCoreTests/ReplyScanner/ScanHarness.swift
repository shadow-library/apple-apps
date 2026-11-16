import Foundation

@testable import NovelForgeCore

struct ScanResult: Equatable {
  var reply = ""
  var elements: [ChangeSetElement] = []
  var state = ReplyScanState.awaitingReply
  var replyPieces: [String] = []

  static func == (lhs: ScanResult, rhs: ScanResult) -> Bool {
    lhs.reply == rhs.reply && lhs.elements == rhs.elements && lhs.state == rhs.state
  }
}

func scan(chunks: [[UInt16]]) -> ScanResult {
  var scanner = ReplyScanner()
  var result = ScanResult()
  func absorb(_ events: [ReplyScanEvent]) {
    for event in events {
      switch event {
      case .reply(let text):
        result.reply += text
        result.replyPieces.append(text)
      case .element(let element):
        result.elements.append(element)
      }
    }
  }
  for chunk in chunks { absorb(scanner.consume(utf16: chunk)) }
  absorb(scanner.finish())
  result.state = scanner.state
  return result
}

func scan(_ text: String, sizes: [Int] = []) -> ScanResult {
  scan(chunks: split(Array(text.utf16), sizes: sizes))
}

func scan(_ text: String, everyTwoChunkSplit: Bool) -> [ScanResult] {
  let units = Array(text.utf16)
  return (0...units.count).map { cut in scan(chunks: [Array(units[..<cut]), Array(units[cut...])]) }
}

func split(_ units: [UInt16], sizes: [Int]) -> [[UInt16]] {
  var chunks: [[UInt16]] = []
  var offset = 0
  for size in sizes where offset < units.count {
    let end = min(units.count, offset + max(size, 1))
    chunks.append(Array(units[offset..<end]))
    offset = end
  }
  if offset < units.count { chunks.append(Array(units[offset...])) }
  return chunks
}

indirect enum JSONTree: Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string([UInt16])
  case array([JSONTree])
  case object([[UInt16]: JSONTree])

  static func parse(_ text: String) -> JSONTree? {
    var parser = TreeParser(units: Array(text.utf16))
    guard let value = parser.value() else { return nil }
    parser.skipWhitespace()
    return parser.index == parser.units.count ? value : nil
  }

  var opString: String? {
    guard case .object(let members) = self, case .string(let units)? = members[Array("op".utf16)] else { return nil }
    return String(decoding: units, as: UTF16.self)
  }
}

private struct TreeParser {
  let units: [UInt16]
  var index = 0

  mutating func skipWhitespace() {
    while index < units.count, [0x20, 0x09, 0x0A, 0x0D].contains(units[index]) { index += 1 }
  }

  mutating func literal(_ word: String, _ result: JSONTree) -> JSONTree? {
    let expected = Array(word.utf16)
    guard index + expected.count <= units.count, Array(units[index..<index + expected.count]) == expected else { return nil }
    index += expected.count
    return result
  }

  mutating func value() -> JSONTree? {
    skipWhitespace()
    guard index < units.count else { return nil }
    switch units[index] {
    case 0x7B: return object()
    case 0x5B: return array()
    case 0x22: return string().map(JSONTree.string)
    case 0x74: return literal("true", .bool(true))
    case 0x66: return literal("false", .bool(false))
    case 0x6E: return literal("null", .null)
    default: return number()
    }
  }

  mutating func object() -> JSONTree? {
    index += 1
    var members: [[UInt16]: JSONTree] = [:]
    skipWhitespace()
    if index < units.count, units[index] == 0x7D {
      index += 1
      return .object(members)
    }
    while true {
      skipWhitespace()
      guard index < units.count, units[index] == 0x22, let key = string() else { return nil }
      skipWhitespace()
      guard index < units.count, units[index] == 0x3A else { return nil }
      index += 1
      guard let member = value() else { return nil }
      members[key] = member
      skipWhitespace()
      guard index < units.count else { return nil }
      index += 1
      if units[index - 1] == 0x7D { return .object(members) }
      guard units[index - 1] == 0x2C else { return nil }
    }
  }

  mutating func array() -> JSONTree? {
    index += 1
    var items: [JSONTree] = []
    skipWhitespace()
    if index < units.count, units[index] == 0x5D {
      index += 1
      return .array(items)
    }
    while true {
      guard let item = value() else { return nil }
      items.append(item)
      skipWhitespace()
      guard index < units.count else { return nil }
      index += 1
      if units[index - 1] == 0x5D { return .array(items) }
      guard units[index - 1] == 0x2C else { return nil }
    }
  }

  mutating func string() -> [UInt16]? {
    index += 1
    var out: [UInt16] = []
    while index < units.count {
      let unit = units[index]
      index += 1
      if unit == 0x22 { return out }
      guard unit == 0x5C else {
        out.append(unit)
        continue
      }
      guard index < units.count else { return nil }
      let escape = units[index]
      index += 1
      switch escape {
      case 0x22, 0x5C, 0x2F: out.append(escape)
      case 0x62: out.append(0x08)
      case 0x66: out.append(0x0C)
      case 0x6E: out.append(0x0A)
      case 0x72: out.append(0x0D)
      case 0x74: out.append(0x09)
      case 0x75:
        guard index + 4 <= units.count, let code = UInt16(String(decoding: units[index..<index + 4], as: UTF16.self), radix: 16) else { return nil }
        index += 4
        out.append(code)
      default: return nil
      }
    }
    return nil
  }

  mutating func number() -> JSONTree? {
    let start = index
    while index < units.count, "+-.eE0123456789".utf16.contains(units[index]) { index += 1 }
    let text = String(decoding: units[start..<index], as: UTF16.self)
    guard let value = Double(text) else { return nil }
    return .number(value)
  }
}

func jsonEqual(_ lhs: String, _ rhs: String) -> Bool {
  guard let left = JSONTree.parse(lhs), let right = JSONTree.parse(rhs) else { return false }
  return left == right
}
