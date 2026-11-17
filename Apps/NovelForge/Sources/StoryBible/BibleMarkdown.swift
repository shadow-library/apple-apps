import Foundation

nonisolated enum BibleMarkdown {
  static func render(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    guard var rendered = try? AttributedString(markdown: source, options: options) else { return AttributedString(source) }
    for run in rendered.runs where run.link != nil { rendered[run.range].link = nil }
    return rendered
  }
}
