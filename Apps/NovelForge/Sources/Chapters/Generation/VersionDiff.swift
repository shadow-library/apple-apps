import Foundation

nonisolated enum DiffOp: Sendable, Equatable {
  case equal
  case insert
  case delete
}

nonisolated struct DiffPiece: Sendable, Equatable {
  let op: DiffOp
  let text: String
}

nonisolated struct DiffParagraph: Sendable, Equatable {
  let pieces: [DiffPiece]

  var changed: Bool { pieces.contains { $0.op != .equal && !$0.text.allSatisfy(\.isWhitespace) } }
}

nonisolated enum DiffRow: Sendable, Equatable {
  case paragraph(DiffParagraph)
  case unchanged(Int)
}

/// apps/novel-forge-web/src/lib/draft-versions.ts:72-135 over a diff made here: paragraphs first, then words inside the paragraphs that changed.
nonisolated struct VersionDiff: Sendable, Equatable {
  let rows: [DiffRow]
  let wordsAdded: Int
  let wordsRemoved: Int

  var isIdentical: Bool {
    !rows.contains {
      guard case .paragraph(let paragraph) = $0 else { return false }
      return paragraph.changed
    }
  }

  private static let cellLimit = 4_000_000

  static func compare(from older: String, to newer: String, context: Int = 1) -> VersionDiff {
    var paragraphs: [DiffParagraph] = []
    var removed: [String] = []
    var added: [String] = []
    func flush() {
      for index in 0..<max(removed.count, added.count) {
        switch (index < removed.count ? removed[index] : nil, index < added.count ? added[index] : nil) {
        case (let old?, let new?): paragraphs.append(DiffParagraph(pieces: words(old, new)))
        case (let old?, nil): paragraphs.append(DiffParagraph(pieces: [DiffPiece(op: .delete, text: old)]))
        case (nil, let new?): paragraphs.append(DiffParagraph(pieces: [DiffPiece(op: .insert, text: new)]))
        case (nil, nil): break
        }
      }
      (removed, added) = ([], [])
    }
    for (op, text) in diff(splitParagraphs(older), splitParagraphs(newer)) {
      switch op {
      case .equal:
        flush()
        paragraphs.append(DiffParagraph(pieces: [DiffPiece(op: .equal, text: text)]))
      case .delete: removed.append(text)
      case .insert: added.append(text)
      }
    }
    flush()
    let pieces = paragraphs.flatMap(\.pieces)
    return VersionDiff(
      rows: fold(paragraphs, context: context), wordsAdded: pieces.filter { $0.op == .insert }.reduce(0) { $0 + wordCount($1.text) },
      wordsRemoved: pieces.filter { $0.op == .delete }.reduce(0) { $0 + wordCount($1.text) })
  }

  private static func fold(_ paragraphs: [DiffParagraph], context: Int) -> [DiffRow] {
    var rows: [DiffRow] = []
    var folded = 0
    for (index, paragraph) in paragraphs.enumerated() {
      let near = paragraphs[max(0, index - context)...min(paragraphs.count - 1, index + context)].contains { $0.changed }
      guard near else {
        folded += 1
        continue
      }
      if folded > 0 { rows.append(.unchanged(folded)) }
      folded = 0
      rows.append(.paragraph(paragraph))
    }
    if folded > 0 { rows.append(.unchanged(folded)) }
    return rows
  }

  private static func words(_ older: String, _ newer: String) -> [DiffPiece] {
    var pieces: [DiffPiece] = []
    var run: (op: DiffOp, words: [String])?
    func close() {
      guard let run else { return }
      pieces.append(DiffPiece(op: run.op, text: join(run.words)))
    }
    for (op, word) in diff(tokens(older), tokens(newer)) {
      if run?.op == op {
        run?.words.append(word)
      } else {
        close()
        run = (op, [word])
      }
    }
    close()
    return pieces
  }

  private static let lineBreak = "\n"

  private static func tokens(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().flatMap { index, line in
      (index > 0 ? [lineBreak] : []) + line.split(whereSeparator: \.isWhitespace).map(String.init)
    }
  }

  private static func join(_ tokens: [String]) -> String {
    var text = ""
    for token in tokens {
      if !text.isEmpty, token != lineBreak, !text.hasSuffix(lineBreak) { text += " " }
      text += token
    }
    return text
  }

  private static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  static func splitParagraphs(_ text: String) -> [String] {
    var paragraphs: [String] = []
    var lines: [Substring] = []
    func close() {
      guard !lines.isEmpty else { return }
      paragraphs.append(lines.joined(separator: "\n"))
      lines = []
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.allSatisfy(\.isWhitespace) { close() } else { lines.append(line) }
    }
    close()
    return paragraphs
  }

  static func diff<Element: Hashable>(_ older: [Element], _ newer: [Element]) -> [(DiffOp, Element)] {
    var head = 0
    while head < older.count, head < newer.count, older[head] == newer[head] { head += 1 }
    var tail = 0
    while tail < older.count - head, tail < newer.count - head, older[older.count - 1 - tail] == newer[newer.count - 1 - tail] { tail += 1 }
    let (left, right) = (Array(older[head..<(older.count - tail)]), Array(newer[head..<(newer.count - tail)]))
    let middle = left.count * right.count > cellLimit ? left.map { (DiffOp.delete, $0) } + right.map { (DiffOp.insert, $0) } : longestCommon(left, right)
    return older[..<head].map { (DiffOp.equal, $0) } + middle + older[(older.count - tail)...].map { (DiffOp.equal, $0) }
  }

  private static func longestCommon<Element: Hashable>(_ left: [Element], _ right: [Element]) -> [(DiffOp, Element)] {
    let (rows, columns) = (left.count, right.count)
    guard rows > 0, columns > 0 else { return left.map { (DiffOp.delete, $0) } + right.map { (DiffOp.insert, $0) } }
    let width = columns + 1
    var table = [UInt32](repeating: 0, count: (rows + 1) * width)
    for row in stride(from: rows - 1, through: 0, by: -1) {
      for column in stride(from: columns - 1, through: 0, by: -1) {
        table[row * width + column] =
          left[row] == right[column] ? table[(row + 1) * width + column + 1] + 1 : max(table[(row + 1) * width + column], table[row * width + column + 1])
      }
    }
    var result: [(DiffOp, Element)] = []
    var (row, column) = (0, 0)
    while row < rows, column < columns {
      if left[row] == right[column] {
        result.append((.equal, left[row]))
        (row, column) = (row + 1, column + 1)
      } else if table[(row + 1) * width + column] >= table[row * width + column + 1] {
        result.append((.delete, left[row]))
        row += 1
      } else {
        result.append((.insert, right[column]))
        column += 1
      }
    }
    result += left[row...].map { (DiffOp.delete, $0) }
    result += right[column...].map { (DiffOp.insert, $0) }
    return result
  }
}
