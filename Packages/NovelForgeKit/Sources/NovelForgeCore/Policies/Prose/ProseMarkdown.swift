import Foundation
import ShadowText

enum ProseMarkdownRegex {
  // apps/novel-forge-server/src/common/sanitize-content.ts:3
  static let dangerousScheme = ProseRegex.literal(#"^(?:javascript|vbscript|data):"#)
  // sanitize-content.ts:10
  static let entity = ProseRegex.literal(#"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);?"#, "g")
}

/// The reference's markdown sanitizer (apps/novel-forge-server/src/common/sanitize-content.ts:71) for native rendering: links and images with a script-capable
/// destination collapse to their text (sanitize-content.ts:42) and raw HTML is shown as text (sanitize-content.ts:40), so nothing the reader draws can run or load.
public enum ProseMarkdown {
  private static let namedEntities: [String: String] = [
    "colon": ":", "tab": "\t", "newline": "\n", "sol": "/", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
  ]

  public static func sanitize(_ content: String) -> String {
    guard !content.isEmpty else { return content }
    return neutralize(Array(droppingDangerousDefinitions(normalizeLineEndings(content))))
  }

  // sanitize-content.ts:20
  public static func isDangerousURL(_ url: String) -> Bool {
    let stripped = String(String.UnicodeScalarView(decodeEntities(url).unicodeScalars.filter { $0.value > 0x20 }))
    return ProseMarkdownRegex.dangerousScheme.test(stripped.jsToLowerCase())
  }

  // sanitize-content.ts:9
  static func decodeEntities(_ input: String) -> String {
    input.jsReplace(ProseMarkdownRegex.entity) { match in
      guard let body = match.groups[0] else { return match.text }
      guard body.hasPrefix("#") else { return namedEntities[body.jsToLowerCase()] ?? match.text }
      let hex = body.dropFirst().first == "x" || body.dropFirst().first == "X"
      let digits = body.dropFirst(hex ? 2 : 1)
      guard let code = UInt32(digits, radix: hex ? 16 : 10), code <= 0x10FFFF, let scalar = Unicode.Scalar(code) else { return match.text }
      return String(Character(scalar))
    }
  }

  private static func neutralize(_ text: [Character]) -> String {
    var output = ""
    var index = 0
    while index < text.count {
      let character = text[index]
      if character == "\\", index + 1 < text.count {
        output.append(character)
        output.append(text[index + 1])
        index += 2
        continue
      }
      if character == "`", let end = codeSpanEnd(in: text, at: index) {
        output += String(text[index..<end])
        index = end
        continue
      }
      if character == "<", let (inner, next) = autolink(in: text, at: index) {
        output += isDangerousURL(inner) ? inner : "<\(inner)>"
        index = next
        continue
      }
      if character == "<", index + 1 < text.count, startsMarkup(text[index + 1]) {
        output += "\\<"
        index += 1
        continue
      }
      if character == "[" || (character == "!" && index + 1 < text.count && text[index + 1] == "["), let link = link(in: text, at: index) {
        if isDangerousURL(unescapingPunctuation(link.destination)) {
          output += neutralize(link.label)
        } else {
          output += String(text[index...link.open]) + neutralize(link.label) + String(text[link.close..<link.end])
        }
        index = link.end
        continue
      }
      output.append(character)
      index += 1
    }
    return output
  }

  private static func startsMarkup(_ character: Character) -> Bool {
    character.isLetter || character == "/" || character == "!" || character == "?"
  }

  private static func autolink(in text: [Character], at start: Int) -> (String, Int)? {
    var index = start + 1
    guard index < text.count, text[index].isASCII, text[index].isLetter else { return nil }
    while index < text.count, text[index] != ">", !text[index].isWhitespace, text[index] != "<" { index += 1 }
    guard index < text.count, text[index] == ">" else { return nil }
    let inner = String(text[(start + 1)..<index])
    guard let colon = inner.firstIndex(of: ":"), inner.distance(from: inner.startIndex, to: colon) >= 2 else { return nil }
    return (inner, index + 1)
  }

  private struct Link {
    let open: Int
    let close: Int
    let label: [Character]
    let destination: String
    let end: Int
  }

  private static func link(in text: [Character], at start: Int) -> Link? {
    let open = text[start] == "!" ? start + 1 : start
    guard let close = matching(text, open: open, opener: "[", closer: "]"), close + 1 < text.count, text[close + 1] == "(" else { return nil }
    var index = close + 2
    while index < text.count, text[index].isWhitespace { index += 1 }
    let destinationStart = index
    if index < text.count, text[index] == "<" {
      while index < text.count, text[index] != ">", text[index] != "\n" { index += 1 }
      guard index < text.count, text[index] == ">" else { return nil }
      let destination = String(text[(destinationStart + 1)..<index])
      index += 1
      guard let end = closingParenthesis(text, from: index) else { return nil }
      return Link(open: open, close: close, label: Array(text[(open + 1)..<close]), destination: destination, end: end)
    }
    var depth = 0
    while index < text.count, !text[index].isWhitespace {
      if text[index] == "\\" {
        index += 1
      } else if text[index] == "(" {
        depth += 1
      } else if text[index] == ")" {
        if depth == 0 { break }
        depth -= 1
      }
      index += 1
    }
    let destination = String(text[destinationStart..<min(index, text.count)])
    guard let end = closingParenthesis(text, from: index) else { return nil }
    return Link(open: open, close: close, label: Array(text[(open + 1)..<close]), destination: destination, end: end)
  }

  private static func closingParenthesis(_ text: [Character], from start: Int) -> Int? {
    var index = start
    while index < text.count, text[index].isWhitespace { index += 1 }
    guard index < text.count else { return nil }
    if text[index] == ")" { return index + 1 }
    guard let closer = titleCloser(text[index]) else { return nil }
    index += 1
    while index < text.count, text[index] != closer {
      if text[index] == "\\" { index += 1 }
      index += 1
    }
    guard index < text.count else { return nil }
    index += 1
    while index < text.count, text[index].isWhitespace { index += 1 }
    guard index < text.count, text[index] == ")" else { return nil }
    return index + 1
  }

  private static func titleCloser(_ opener: Character) -> Character? {
    switch opener {
    case "\"": "\""
    case "'": "'"
    case "(": ")"
    default: nil
    }
  }

  private static func matching(_ text: [Character], open: Int, opener: Character, closer: Character) -> Int? {
    var depth = 0
    var index = open
    while index < text.count {
      if text[index] == "\\" {
        index += 2
        continue
      }
      if text[index] == opener {
        depth += 1
      } else if text[index] == closer {
        depth -= 1
        if depth == 0 { return index }
      }
      index += 1
    }
    return nil
  }

  private static func codeSpanEnd(in text: [Character], at start: Int) -> Int? {
    var length = 0
    while start + length < text.count, text[start + length] == "`" { length += 1 }
    var index = start + length
    while index < text.count {
      if text[index] == "\n", startsBlankLine(text, after: index) { return nil }
      guard text[index] == "`" else {
        index += 1
        continue
      }
      var run = 0
      while index + run < text.count, text[index + run] == "`" { run += 1 }
      if run == length { return index + run }
      index += run
    }
    return nil
  }

  private static func startsBlankLine(_ text: [Character], after newline: Int) -> Bool {
    var index = newline + 1
    while index < text.count, text[index] == " " || text[index] == "\t" { index += 1 }
    return index < text.count && text[index] == "\n"
  }

  private static func unescapingPunctuation(_ text: String) -> String {
    var output = ""
    var escaped = false
    for character in text {
      if escaped, character.isASCII, character.isPunctuation || character.isSymbol {
        output.append(character)
      } else if escaped {
        output.append("\\")
        output.append(character)
      } else if character != "\\" {
        output.append(character)
      }
      escaped = character == "\\" && !escaped
    }
    if escaped { output.append("\\") }
    return output
  }

  private static func droppingDangerousDefinitions(_ text: String) -> String {
    let lines = text.jsSplit("\n")
    var kept = [String]()
    var fence: Character?
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.drop { $0 == " " }
      if line.allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
      if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.prefix(3).allSatisfy({ $0 == marker }) {
        fence = fence == nil ? marker : (fence == marker ? nil : fence)
        kept.append(line)
        index += 1
        continue
      }
      guard fence == nil, let definition = definition(in: lines, at: index), isDangerousURL(unescapingPunctuation(definition.destination)) else {
        kept.append(line)
        index += 1
        continue
      }
      index += definition.lines
    }
    return kept.joined(separator: "\n")
  }

  private static func definition(in lines: [String], at index: Int) -> (destination: String, lines: Int)? {
    var rest = Substring(lines[index])
    while let first = rest.first {
      if first == " " || first == ">" {
        rest = rest.dropFirst()
      } else if ["-", "*", "+"].contains(first), rest.dropFirst().first == " " {
        rest = rest.dropFirst(2)
      } else if first.isASCII, first.isNumber {
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { break }
        rest = after.dropFirst(2)
      } else {
        break
      }
    }
    guard rest.first == "[" else { return nil }
    var cursor = rest.dropFirst()
    var escaped = false
    while let character = cursor.first {
      if character == "]", !escaped { break }
      escaped = character == "\\" && !escaped
      cursor = cursor.dropFirst()
    }
    guard cursor.first == "]", cursor.dropFirst().first == ":" else { return nil }
    var tail = cursor.dropFirst(2).drop { $0 == " " || $0 == "\t" }
    var consumed = 1
    if tail.isEmpty {
      guard index + 1 < lines.count else { return nil }
      tail = Substring(lines[index + 1]).drop { $0 == " " || $0 == "\t" }
      consumed = 2
    }
    guard !tail.isEmpty else { return nil }
    if tail.first == "<" {
      let inner = tail.dropFirst().prefix { $0 != ">" }
      return (String(inner), consumed)
    }
    return (String(tail.prefix { !$0.isWhitespace }), consumed)
  }
}
