extension OrderedJSON {
  /// `JSON.stringify(value)`; every number goes through a double, as JavaScript would read it, and a number that is not finite is `null`.
  public var jsonText: String {
    var out = ""
    append(to: &out)
    return out
  }

  private func append(to out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let flag): out += flag ? "true" : "false"
    case .int(let number): out += Double(number).jsString
    case .double(let number): out += number.isFinite ? number.jsString : "null"
    case .string(let text): Self.appendQuoted(text, to: &out)
    case .array(let items):
      out += "["
      for (index, item) in items.enumerated() {
        if index > 0 { out += "," }
        item.append(to: &out)
      }
      out += "]"
    case .object(let object):
      out += "{"
      for (index, entry) in object.entries.enumerated() {
        if index > 0 { out += "," }
        Self.appendQuoted(entry.key, to: &out)
        out += ":"
        entry.value.append(to: &out)
      }
      out += "}"
    }
  }

  private static func appendQuoted(_ text: String, to out: inout String) {
    out += "\""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0..<0x20:
        let digits = String(scalar.value, radix: 16)
        out += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
      default: out.unicodeScalars.append(scalar)
      }
    }
    out += "\""
  }
}
