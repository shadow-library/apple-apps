import ShadowTestSupport

@testable import NovelForgeCore

enum TextSamples {
  static let ascii = ["a", "b", "Z", "s", "S", "i", "I", "0", "7", " ", "-", ".", "?", "!", "'", "\"", "_", "|", "\\", "$", "&", "`", ":", "/"]
  static let accents = ["é", "Ö", "ñ", "Å", "e\u{301}", "o\u{308}", "A\u{30A}", "\u{301}", "\u{327}", "\u{345}"]
  static let astral = ["𝒜", "𠀀", "😀", "👨‍👩‍👧", "👍🏽", "❤️", "🇫🇷", "1️⃣", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"]
  static let whitespace = [
    "\t", "\n", "\u{B}", "\u{C}", "\r", " ", "\u{85}", "\u{A0}", "\u{1680}", "\u{180E}", "\u{2000}", "\u{2005}", "\u{200A}", "\u{200B}", "\u{2028}", "\u{2029}",
    "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}", "\r\n",
  ]
  static let casing = ["İ", "ı", "ß", "ẞ", "Σ", "σ", "ς", "Α", "ΐ", "ﬁ", "ﬀ", "ǅ", "Ǆ", "ŉ", "K", "Ω", "Å", "ｱ", "①", "ſ"]
  static let digits = ["٣", "५", "１", "²", "Ⅻ", "߁"]
  static let invisible = ["\u{200C}", "\u{200D}", "\u{2060}", "\u{FE0F}", "\u{FEFF}", "\u{00AD}"]
  static let scripts = ["中", "文", "。", "あ", "カ", "ー", "ไ", "’", "“", "”", "—", "…"]
  static let pieces = ascii + accents + astral + whitespace + casing + digits + invisible + scripts
}

extension SeededGenerator {
  mutating func jsText(maxPieces: Int = 12) -> String {
    (0..<int(in: 0...maxPieces)).map { _ in pick(from: TextSamples.pieces) }.joined()
  }

  mutating func jsNeedle(in text: String) -> String {
    if chance(0.3) { return jsText(maxPieces: 2) }
    let length = text.jsLength
    let start = int(in: 0...length)
    return text.jsSlice(start, start + int(in: 0...3))
  }

  mutating func jsPosition(around length: Int) -> Double {
    if chance(0.25) { return pick(from: [Double.nan, .infinity, -.infinity, -0.0, 0.5, -0.5, 1.5, Double(length) + 0.5]) }
    return Double(int(in: (-length - 3)...(length + 3)))
  }
}
