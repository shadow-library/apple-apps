import Foundation
import NovelForgeCore

nonisolated enum ProseBlock: Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case quote(String)
  case list([String])
  case rule
}

nonisolated enum ProseBlocks {
  private static let safeSchemes: Set<String> = ["http", "https", "mailto"]

  static func parse(_ markdown: String) -> [ProseBlock] {
    var blocks = [ProseBlock]()
    var group = [Substring]()
    for line in ProseMarkdown.sanitize(markdown).split(separator: "\n", omittingEmptySubsequences: false) {
      if line.allSatisfy(\.isWhitespace) {
        blocks += flush(&group)
      } else {
        group.append(line)
      }
    }
    return blocks + flush(&group)
  }

  static func attributed(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    for run in attributed.runs {
      guard let link = run.link, !isSafe(link) else { continue }
      attributed[run.range].link = nil
    }
    return attributed
  }

  static func isSafe(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return safeSchemes.contains(scheme)
  }

  private static func flush(_ group: inout [Substring]) -> [ProseBlock] {
    defer { group.removeAll() }
    guard !group.isEmpty else { return [] }
    var blocks = [ProseBlock]()
    var paragraph = [Substring]()
    func closeParagraph() {
      guard !paragraph.isEmpty else { return }
      blocks.append(block(for: paragraph))
      paragraph.removeAll()
    }
    for line in group {
      if let heading = heading(in: line) {
        closeParagraph()
        blocks.append(heading)
      } else if isRule(line) {
        closeParagraph()
        blocks.append(.rule)
      } else {
        paragraph.append(line)
      }
    }
    closeParagraph()
    return blocks
  }

  private static func block(for lines: [Substring]) -> ProseBlock {
    if lines.allSatisfy({ $0.drop(while: { $0 == " " }).hasPrefix(">") }) {
      return .quote(lines.map { String($0.drop(while: { $0 == " " }).dropFirst().drop(while: { $0 == " " })) }.joined(separator: "\n"))
    }
    let items = lines.compactMap(listItem)
    if items.count == lines.count { return .list(items) }
    return .paragraph(lines.joined(separator: "\n"))
  }

  private static func heading(in line: Substring) -> ProseBlock? {
    let trimmed = line.drop(while: { $0 == " " })
    let level = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level), line.count - trimmed.count <= 3 else { return nil }
    let rest = trimmed.dropFirst(level)
    guard rest.first == " " else { return nil }
    let text = rest.drop(while: { $0 == " " }).reversed().drop(while: { $0 == "#" || $0 == " " }).reversed()
    return .heading(level: level, text: String(text))
  }

  private static func isRule(_ line: Substring) -> Bool {
    let marks = line.filter { !$0.isWhitespace }
    guard marks.count >= 3, let first = marks.first, ["*", "-", "_"].contains(first) else { return false }
    return marks.allSatisfy { $0 == first }
  }

  private static func listItem(_ line: Substring) -> String? {
    let trimmed = line.drop(while: { $0 == " " })
    guard let marker = trimmed.first, ["-", "*", "+"].contains(marker), trimmed.dropFirst().first == " " else { return nil }
    return String(trimmed.dropFirst(2))
  }
}
