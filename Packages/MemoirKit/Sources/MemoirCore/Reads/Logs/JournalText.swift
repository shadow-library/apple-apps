import ShadowText

/// memoir-web's journal text rules (`lib/data/quick-logs.rules.ts:115-134`) on `ShadowText`, so words and excerpts match the web's character for character.
public enum JournalText {
  public static let excerptLength = 160

  /// `ShadowText` has no `m` flag; a multiline `^` matches where no character other than a line terminator precedes, which this lookbehind states.
  private static let lineStart = "(?<![^\\n\\r\\u2028\\u2029])"
  private static let patterns: [(JSRegex, String)] = [
    (pattern(lineStart + "\\s{0,3}>\\s?", flags: "g"), ""),
    (pattern(lineStart + "\\s{0,3}#{1,3}\\s+", flags: "g"), ""),
    (pattern(lineStart + "\\s{0,3}[-*]\\s+", flags: "g"), ""),
    (pattern("\\*\\*(.+?)\\*\\*", flags: "g"), "$1"),
    (pattern("_(.+?)_", flags: "g"), "$1"),
    (pattern("\\s+", flags: "g"), " "),
  ]
  private static let whitespace = pattern("\\s+", flags: "")

  /// `journalWordCount`: words of the text with markdown-lite marks taken out.
  public static func wordCount(_ text: String) -> Int {
    plainText(text).jsTrim().jsSplit(whitespace).count { !$0.isEmpty }
  }

  /// `journalExcerpt`: the plain text, cut to `maxLength` UTF-16 units with an ellipsis when longer.
  public static func excerpt(_ text: String, maxLength: Int = excerptLength) -> String {
    let plain = plainText(text).jsTrim()
    return plain.jsLength <= maxLength ? plain : "\(plain.jsSlice(0, maxLength).jsTrimEnd())\u{2026}"
  }

  /// `markdownLitePlainText`: bold, italic, headings, bullets and quotes removed; nothing else is read.
  static func plainText(_ text: String) -> String {
    patterns.reduce(text) { text, rule in text.jsReplace(rule.0, rule.1) }
  }

  private static func pattern(_ source: String, flags: String) -> JSRegex {
    do {
      return try JSRegex(source, flags: flags)
    } catch {
      preconditionFailure("the journal pattern \(source) is a valid regular expression: \(error)")
    }
  }
}
