import Foundation

/// The repository's `THIRD_PARTY_NOTICES.md`, bundled as `ThirdPartyNotices.md` and read as the few Markdown blocks it uses.
public nonisolated struct Acknowledgements: Equatable, Sendable {
  public enum Block: Equatable, Sendable {
    case heading(level: Int, text: String)
    case item(String)
    case paragraph(String)
    case preformatted(String)
  }

  public let blocks: [Block]

  public init(markdown: String) {
    var blocks: [Block] = []
    var paragraph: [Substring] = []
    var fence: [Substring]?

    func closeParagraph() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
      paragraph = []
    }

    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingSuffix(while: \.isWhitespace) }) {
      if var lines = fence {
        if line.hasPrefix("```") {
          blocks.append(.preformatted(lines.joined(separator: "\n")))
          fence = nil
        } else {
          lines.append(line)
          fence = lines
        }
        continue
      }
      if line.hasPrefix("```") {
        closeParagraph()
        fence = []
      } else if line.isEmpty {
        closeParagraph()
      } else if let heading = Self.heading(line) {
        closeParagraph()
        blocks.append(heading)
      } else if line.hasPrefix("- ") {
        closeParagraph()
        blocks.append(.item(String(line.dropFirst(2))))
      } else {
        paragraph.append(line)
      }
    }
    closeParagraph()
    if let fence { blocks.append(.preformatted(fence.joined(separator: "\n"))) }
    self.blocks = blocks
  }

  /// Nil when the bundle holds no notices, so the screen leaves the row out rather than showing an empty page.
  public static let bundled = load(from: .module)

  static func load(from bundle: Bundle) -> Acknowledgements? {
    guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "md"), let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let acknowledgements = Acknowledgements(markdown: markdown)
    return acknowledgements.blocks.isEmpty ? nil : acknowledgements
  }

  private static func heading(_ line: Substring) -> Block? {
    let level = line.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
    return .heading(level: level, text: String(line.dropFirst(level + 1)))
  }
}

extension Substring {
  nonisolated fileprivate func trimmingSuffix(while predicate: (Character) -> Bool) -> Substring {
    var end = endIndex
    while end > startIndex, predicate(self[index(before: end)]) { end = index(before: end) }
    return self[startIndex..<end]
  }
}
