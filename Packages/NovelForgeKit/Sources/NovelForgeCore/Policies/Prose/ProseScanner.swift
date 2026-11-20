import ShadowText

private struct Line {
  let start: Int
  let text: String
}

extension [Line] {
  fileprivate func line(at index: Int) -> Line? {
    indices.contains(index) ? self[index] : nil
  }
}

struct ProseScanner: Sendable {
  static let shared: ProseScanner? = try? ProseScanner()

  private let blank: JSRegex
  private let sceneBreak: JSRegex
  private let setextUnderline: JSRegex
  private let heading: JSRegex
  private let fence: JSRegex
  private let quote: JSRegex
  private let listItem: JSRegex
  private let listAfterText: JSRegex
  private let delimiterCell: JSRegex
  private let lineBreak: JSRegex
  private let unescapedPipe: JSRegex

  init() throws(JSRegexError) {
    blank = try JSRegex(#"^[ \t]*$"#)
    sceneBreak = try JSRegex(#"^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    setextUnderline = try JSRegex(#"^ {0,3}(?:=+|-+)[ \t]*$"#)
    heading = try JSRegex(#"^ {0,3}#{1,6}(?:[ \t]|$)"#)
    fence = try JSRegex(#"^ {0,3}(`{3,}(?=[^`]*$)|~{3,})"#)
    quote = try JSRegex(#"^ {0,3}>"#)
    listItem = try JSRegex(#"^ {0,3}(?:[-+*]|\d{1,9}[.)])(?:[ \t]|$)"#)
    listAfterText = try JSRegex(#"^ {0,3}(?:[-+*]|1[.)])[ \t]+\S"#)
    delimiterCell = try JSRegex(#"^[ \t]*:?-+:?[ \t]*$"#)
    lineBreak = try JSRegex(#"\r\n|\r|\n"#, flags: "g")
    unescapedPipe = try JSRegex(#"(?<!\\)\|"#)
  }

  // packages/sdk/src/prose-paragraphs.ts:150
  func paragraphs(in text: String) -> [ProseParagraph] {
    let lines = linesOf(text)
    var paragraphs: [ProseParagraph] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if isBlank(line) || sceneBreak.test(line.text) {
        index += 1
        continue
      }
      let last = blockEnd(lines, from: index)
      let final = lines[last]
      paragraphs.append(
        ProseParagraph(start: line.start + line.text.jsLength - line.text.jsTrimStart().jsLength, end: final.start + final.text.jsTrimEnd().jsLength)
      )
      index = last + 1
    }
    return paragraphs
  }

  // packages/sdk/src/prose-paragraphs.ts:25
  private func linesOf(_ text: String) -> [Line] {
    let units = text.jsCodeUnits
    var lines: [Line] = []
    var start = 0
    for found in text.jsMatchAll(lineBreak) {
      lines.append(Line(start: start, text: JSText.string(fromCodeUnits: units[start..<found.index])))
      start = found.endIndex
    }
    lines.append(Line(start: start, text: JSText.string(fromCodeUnits: units[start...])))
    return lines
  }

  // packages/sdk/src/prose-paragraphs.ts:36
  private func indentOf(_ text: String) -> Int {
    var width = 0
    for scalar in text.unicodeScalars {
      if scalar == " " {
        width += 1
      } else if scalar == "\t" {
        width += 4 - (width % 4)
      } else {
        break
      }
    }
    return width
  }

  // packages/sdk/src/prose-paragraphs.ts:46
  private func isBlank(_ line: Line?) -> Bool {
    guard let line else { return true }
    return blank.test(line.text)
  }

  // packages/sdk/src/prose-paragraphs.ts:50
  private func startsBlock(_ text: String) -> Bool {
    sceneBreak.test(text) || heading.test(text) || fence.test(text) || quote.test(text)
  }

  // packages/sdk/src/prose-paragraphs.ts:54
  private func tableCells(_ row: String) -> [String] {
    var text = row.jsTrim()
    if text.jsStartsWith("|") { text = text.jsSlice(1) }
    if text.jsEndsWith("|"), !text.jsEndsWith("\\|") { text = text.jsSlice(0, -1) }
    return text.jsSplit(unescapedPipe)
  }

  // packages/sdk/src/prose-paragraphs.ts:61
  private func startsTable(_ lines: [Line], at index: Int) -> Bool {
    let header = lines.line(at: index)?.text ?? ""
    let delimiter = lines.line(at: index + 1)?.text ?? ""
    if !header.jsIncludes("|") || !delimiter.jsIncludes("|") || indentOf(header) >= 4 || indentOf(delimiter) >= 4 { return false }
    let delimiterCells = tableCells(delimiter)
    return delimiterCells.allSatisfy { delimiterCell.test($0) } && delimiterCells.count == tableCells(header).count
  }

  // packages/sdk/src/prose-paragraphs.ts:68
  private func tableEnd(_ lines: [Line], from: Int) -> Int {
    var last = from + 1
    while !isBlank(lines.line(at: last + 1)), let next = lines.line(at: last + 1) {
      if startsBlock(next.text) || listAfterText.test(next.text) || indentOf(next.text) >= 4 { break }
      last += 1
    }
    return last
  }

  // packages/sdk/src/prose-paragraphs.ts:79
  private func fenceEnd(_ lines: [Line], from: Int, marker: String) -> Int {
    let character = marker.jsCharAt(0) == "`" ? "`" : "~"
    guard let closing = try? JSRegex("^ {0,3}\(character){\(marker.jsLength),}[ \\t]*$") else { return lines.count - 1 }
    for index in (from + 1)..<max(lines.count, from + 1) where closing.test(lines[index].text) { return index }
    return lines.count - 1
  }

  // packages/sdk/src/prose-paragraphs.ts:85
  private func indentedCodeEnd(_ lines: [Line], from: Int) -> Int {
    var last = from
    for index in (from + 1)..<max(lines.count, from + 1) {
      let line = lines[index]
      if isBlank(line) { continue }
      if indentOf(line.text) < 4 { break }
      last = index
    }
    return last
  }

  // packages/sdk/src/prose-paragraphs.ts:96
  private func quoteEnd(_ lines: [Line], from: Int) -> Int {
    var last = from
    while !isBlank(lines.line(at: last + 1)), let next = lines.line(at: last + 1) {
      if !quote.test(next.text), startsBlock(next.text) || listItem.test(next.text) { break }
      last += 1
    }
    return last
  }

  // packages/sdk/src/prose-paragraphs.ts:106
  private func listEnd(_ lines: [Line], from: Int) -> Int {
    var last = from
    for index in (from + 1)..<max(lines.count, from + 1) {
      let line = lines[index]
      if isBlank(line) { continue }
      let afterBlank = index > last + 1
      if sceneBreak.test(line.text) { break }
      let continues = (listItem.test(line.text) && indentOf(line.text) < 4) || indentOf(line.text) >= 2 || (!afterBlank && !startsBlock(line.text))
      if !continues { break }
      last = index
    }
    return last
  }

  // packages/sdk/src/prose-paragraphs.ts:119
  private func paragraphEnd(_ lines: [Line], from: Int) -> Int {
    var last = from
    while !isBlank(lines.line(at: last + 1)), let next = lines.line(at: last + 1) {
      if setextUnderline.test(next.text) { return last + 1 }
      if startsBlock(next.text) || listAfterText.test(next.text) || startsTable(lines, at: last + 1) { break }
      last += 1
    }
    return last
  }

  // packages/sdk/src/prose-paragraphs.ts:130
  private func blockEnd(_ lines: [Line], from: Int) -> Int {
    let text = lines[from].text
    if let marker = fence.exec(text)?.groups.first.flatMap({ $0 }), !marker.isEmpty { return fenceEnd(lines, from: from, marker: marker) }
    if heading.test(text) { return from }
    if indentOf(text) >= 4 { return indentedCodeEnd(lines, from: from) }
    if quote.test(text) { return quoteEnd(lines, from: from) }
    if listItem.test(text) { return listEnd(lines, from: from) }
    if startsTable(lines, at: from) { return tableEnd(lines, from: from) }
    return paragraphEnd(lines, from: from)
  }
}
