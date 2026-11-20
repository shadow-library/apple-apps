import Foundation
import ShadowText

indirect enum EvalJSON: Sendable {
  case null
  case bool(Bool)
  case int(Int)
  case number(Double)
  case string(String)
  case raw(String)
  case array([EvalJSON])
  case object([(key: String, value: EvalJSON)])

  var compact: String {
    switch self {
    case .null: "null"
    case .bool(let value): value ? "true" : "false"
    case .int(let value): String(value)
    case .number(let value): Self.format(value)
    case .string(let value): Self.quote(value)
    case .raw(let text): text
    case .array(let items): "[" + items.map(\.compact).joined(separator: ",") + "]"
    case .object(let members): "{" + members.map { Self.quote($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
    }
  }

  var pretty: String { JSONReindent.pretty(compact) }

  static func optional(_ value: String?) -> EvalJSON { value.map(EvalJSON.string) ?? .null }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
  }

  private static func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}

enum JSONReindent {
  private static let indent = "  "

  static func pretty(_ compact: String) -> String {
    var out = ""
    var depth = 0
    var inString = false
    var escaped = false
    let characters = Array(compact)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      index += 1
      if inString {
        out.append(character)
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }
      switch character {
      case "\"":
        inString = true
        out.append(character)
      case "{", "[":
        out.append(character)
        if index < characters.count, characters[index] == (character == "{" ? "}" : "]") {
          out.append(characters[index])
          index += 1
          continue
        }
        depth += 1
        out += "\n" + String(repeating: indent, count: depth)
      case "}", "]":
        depth -= 1
        out += "\n" + String(repeating: indent, count: depth) + String(character)
      case ",": out += ",\n" + String(repeating: indent, count: depth)
      case ":": out += ": "
      default: out.append(character)
      }
    }
    return out
  }
}
