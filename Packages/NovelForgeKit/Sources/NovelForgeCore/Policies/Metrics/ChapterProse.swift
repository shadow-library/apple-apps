import ShadowText

struct ChapterProse: Sendable {
  let prose: String
  let unclosedFence: String?
}

extension ChapterProse {
  private static let fence = ProseRegex.literal(#"^ {0,3}(`{3,}(?=[^`]*$)|~{3,})(.*)$"#)
  private static let systemPanelInfo = ProseRegex.literal(#"^system(?:\s|$)"#, "i")
  private static let blockStart = ProseRegex.literal(#"^ {0,3}(?:#{1,6}(?:[ \t]|$)|>|`{3,}|~{3,})"#)
  private static let tableEndPattern = ProseRegex.literal(
    #"^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$|^ {0,3}(?:[-+*]|1[.)])[ \t]+\S|^(?: {4,}|\t)"#
  )
  private static let delimiterCell = ProseRegex.literal(#"^\s*:?-+:?\s*$"#)
  private static let lineBreak = ProseRegex.literal(#"\r\n|\r|\n"#)
  private static let cellSeparator = ProseRegex.literal(#"(?<!\\)\|"#)

  // apps/novel-forge-server/src/modules/eval/chapter-prose.ts:40
  static func split(_ markdown: String) -> ChapterProse {
    let lines = markdown.jsSplit(lineBreak)
    var kept: [String] = []
    var unclosedFence: String?
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if let opening = fence.exec(line) {
        let close = closingFence(lines, from: index, marker: opening.groups[0] ?? "")
        if close == -1, unclosedFence == nil { unclosedFence = line.jsTrim() }
        if systemPanelInfo.test((opening.groups[1] ?? "").jsTrim()) {
          kept.append("")
        } else {
          kept.append("")
          kept.append(contentsOf: lines[(index + 1)..<(close == -1 ? lines.count : close)])
          kept.append("")
        }
        index = (close == -1 ? lines.count - 1 : close) + 1
        continue
      }
      if startsTable(lines, at: index) {
        kept.append("")
        index = tableEnd(lines, from: index) + 1
        continue
      }
      kept.append(line)
      index += 1
    }
    return ChapterProse(prose: kept.joined(separator: "\n"), unclosedFence: unclosedFence)
  }

  // apps/novel-forge-server/src/modules/eval/chapter-prose.ts:66
  static func proseOnly(_ markdown: String) -> String {
    split(markdown).prose
  }

  private static func closingFence(_ lines: [String], from: Int, marker: String) -> Int {
    let character = marker.jsCharAt(0) == "`" ? "`" : "~"
    let closing = ProseRegex.literal("^ {0,3}\(character){\(marker.jsLength),}[ \\t]*$")
    return ((from + 1)..<max(from + 1, lines.count)).first { closing.test(lines[$0]) } ?? -1
  }

  private static func tableCells(_ row: String) -> [String] {
    var text = row.jsTrim()
    if text.jsStartsWith("|") { text = text.jsSlice(1) }
    if text.jsEndsWith("|"), !text.jsEndsWith("\\|") { text = text.jsSlice(0, -1) }
    return text.jsSplit(cellSeparator)
  }

  private static func startsTable(_ lines: [String], at index: Int) -> Bool {
    let header = lines[index]
    let delimiter = index + 1 < lines.count ? lines[index + 1] : ""
    guard header.jsIncludes("|"), delimiter.jsIncludes("|") else { return false }
    let delimiterCells = tableCells(delimiter)
    return delimiterCells.allSatisfy { delimiterCell.test($0) } && delimiterCells.count == tableCells(header).count
  }

  private static func tableEnd(_ lines: [String], from: Int) -> Int {
    var last = from + 1
    while last + 1 < lines.count, !lines[last + 1].jsTrim().isEmpty, !blockStart.test(lines[last + 1]), !tableEndPattern.test(lines[last + 1]) { last += 1 }
    return last
  }
}
