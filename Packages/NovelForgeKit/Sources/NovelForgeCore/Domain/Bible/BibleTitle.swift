import Foundation
import ShadowCore

// apps/novel-forge-server/src/common/bible-doc-title.ts
enum BibleTitle {
  // bible-doc-title.ts:9
  static func humanise(slug: String) -> String {
    let words = slug.jsReplaceRuns(of: ["-", "_"], with: " ").jsTrim()
    guard let first = words.utf16.first, !UTF16.isLeadSurrogate(first), let head = words.unicodeScalars.first else { return words }
    return String(head).uppercased() + String(words.unicodeScalars.dropFirst())
  }

  // bible-doc-title.ts:13
  static func authored(_ frontmatter: [String: JSONValue]?) -> String? {
    guard let title = frontmatter?["title"]?.stringValue else { return nil }
    let trimmed = title.jsTrim()
    return trimmed.isEmpty ? nil : trimmed
  }

  // bible-doc-title.ts:19
  static func derive(slug: String, frontmatter: [String: JSONValue]?, body: String?) -> String {
    authored(frontmatter) ?? topHeading(in: body ?? "")?.jsTrim() ?? humanise(slug: slug)
  }

  // bible-doc-title.ts:28
  static func ensure(slug: String, frontmatter: [String: JSONValue]?, body: String?) -> [String: JSONValue] {
    if authored(frontmatter) != nil, let frontmatter { return frontmatter }
    var folded = frontmatter ?? [:]
    folded["title"] = .string(derive(slug: slug, frontmatter: frontmatter, body: body))
    return folded
  }

  // The first match of /^#\s+(.+)$/m: `\s` may run over line breaks, and gives back its last character when `.+` would otherwise find nothing
  private static func topHeading(in text: String) -> String? {
    let units = Array(text.utf16)
    var start = 0
    while start < units.count {
      if units[start] == 0x23, let heading = headingText(in: units, hash: start) { return JSText.string(fromCodeUnits: heading) }
      guard let next = units[start...].firstIndex(where: isLineTerminator) else { return nil }
      start = next + 1
    }
    return nil
  }

  private static func headingText(in units: [UInt16], hash: Int) -> ArraySlice<UInt16>? {
    var runEnd = hash + 1
    while runEnd < units.count, isWhitespace(units[runEnd]) { runEnd += 1 }
    guard runEnd > hash + 1 else { return nil }
    for textStart in stride(from: runEnd, through: hash + 2, by: -1) {
      guard textStart < units.count, !isLineTerminator(units[textStart]) else { continue }
      let end = units[textStart...].firstIndex(where: isLineTerminator) ?? units.count
      return units[textStart..<end]
    }
    return nil
  }

  private static func isLineTerminator(_ unit: UInt16) -> Bool {
    unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
  }

  private static func isWhitespace(_ unit: UInt16) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return JSText.isWhitespace(scalar)
  }
}

extension String {
  fileprivate func jsReplaceRuns(of characters: Set<Unicode.Scalar>, with replacement: String) -> String {
    var result = String.UnicodeScalarView()
    var inRun = false
    for scalar in unicodeScalars {
      guard characters.contains(scalar) else {
        result.append(scalar)
        inRun = false
        continue
      }
      if !inRun { result.append(contentsOf: replacement.unicodeScalars) }
      inRun = true
    }
    return String(result)
  }
}
