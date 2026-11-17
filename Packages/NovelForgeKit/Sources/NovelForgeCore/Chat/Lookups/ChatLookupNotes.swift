import Foundation
import ShadowStore

private let notesPartTokens = 800
private let pageTokens = 3_000
private let tokensBudget = 4_500
private let pageCharacters = tokensBudget * 2
private let tokenisedRunCharacters = 32

private struct SizedText {
  var text: String
  var tokens: Int
}

private struct NotesPart {
  let paragraph: Int
  let part: Int
  let parts: Int
  let text: String
  let tokens: Int

  var label: String { parts == 1 ? "¶\(paragraph)" : "¶\(paragraph).\(part)" }
  var continuation: String { part == 1 ? "from: \(paragraph)" : "from: \(paragraph), part: \(part)" }
}

private let wordRun = ProseRegex.literal(#"\s*\S+"#, "g")

// tools/get-notes.tool.ts:40
private func byteBoundedPieces(_ run: String, maxBytes: Int) -> [SizedText] {
  var pieces: [SizedText] = []
  var text = ""
  var bytes = 0
  for scalar in run.unicodeScalars {
    let size = String(scalar).utf8.count
    if !text.isEmpty, bytes + size > maxBytes {
      pieces.append(SizedText(text: text, tokens: bytes))
      text = ""
      bytes = 0
    }
    text.unicodeScalars.append(scalar)
    bytes += size
  }
  if !text.isEmpty { pieces.append(SizedText(text: text, tokens: bytes)) }
  return pieces
}

// tools/get-notes.tool.ts:64
private func sizedRuns(_ text: String, maxTokens: Int, counted: inout [JSString: Int]) -> [SizedText] {
  let matches = text.jsMatchAll(wordRun).map(\.text)
  return (matches.isEmpty ? [text] : matches).flatMap { run -> [SizedText] in
    guard run.jsLength <= tokenisedRunCharacters else { return byteBoundedPieces(run, maxBytes: maxTokens) }
    let tokens = counted[JSString(run)] ?? countTokens(run)
    counted[JSString(run)] = tokens
    return [SizedText(text: run, tokens: tokens)]
  }
}

// tools/get-notes.tool.ts:71
private func sizedParts(_ text: String, maxTokens: Int, counted: inout [JSString: Int]) -> [SizedText] {
  var parts: [SizedText] = []
  var current = SizedText(text: "", tokens: 0)
  for run in sizedRuns(text, maxTokens: maxTokens, counted: &counted) {
    if !current.text.isEmpty, current.tokens + run.tokens > maxTokens {
      parts.append(current)
      current = SizedText(text: "", tokens: 0)
    }
    current = SizedText(text: current.text + run.text, tokens: current.tokens + run.tokens)
  }
  if !current.text.isEmpty { parts.append(current) }
  return parts
}

// tools/get-notes.tool.ts:89
private func notesParts(_ paragraphs: [String], wanted: Set<Int>) -> [NotesPart] {
  var counted: [JSString: Int] = [:]
  return paragraphs.enumerated().flatMap { index, paragraph -> [NotesPart] in
    guard wanted.contains(index + 1) else { return [] }
    let parts = sizedParts(paragraph, maxTokens: notesPartTokens, counted: &counted)
    return parts.enumerated().map { NotesPart(paragraph: index + 1, part: $0.offset + 1, parts: parts.count, text: $0.element.text, tokens: $0.element.tokens) }
  }
}

extension ChatLookupReader {
  // tools/get-notes.tool.ts:110
  func notes(from: Double?, part: Double?, query: String?) throws(ChatLookupFailure) -> String {
    let reading = try self.query { () throws(StoreError) in try NovelNotes.load(novel, in: transaction) }.notes
    guard case .text(let notes) = reading else { throw ChatLookupFailure() }
    let paragraphs = ChatPack.notesParagraphs(notes)
    if paragraphs.isEmpty { return "The author has not stored any notes." }
    let from = from ?? 1
    if from > Double(paragraphs.count) { return "The author's notes have \(paragraphs.count) paragraphs; there is no paragraph \(from.jsString)." }

    let lowered = query?.jsToLowerCase()
    let wanted = Set(
      paragraphs.enumerated().compactMap { index, paragraph in Double(index + 1) >= from && (lowered.map { paragraph.jsToLowerCase().jsIncludes($0) } ?? true) ? index + 1 : nil })
    let startPart = part ?? 1
    let matching = notesParts(paragraphs, wanted: wanted).filter { Double($0.paragraph) > from || Double($0.part) >= startPart }
    if matching.isEmpty { return "Nothing in the author's \(paragraphs.count) paragraphs matches from there on." }

    var lines: [String] = []
    var tokens = 0
    var characters = 0
    for part in matching {
      let label = "[\(part.label)] "
      let line = "\(label)\(part.text)"
      let cost = countTokens(label) + part.tokens
      if !lines.isEmpty, tokens + cost > pageTokens || characters + line.jsLength > pageCharacters { break }
      lines.append(line)
      tokens += cost
      characters += line.jsLength
    }
    let more = lines.count < matching.count ? "\n\n(\(matching.count - lines.count) more — continue with \(matching[lines.count].continuation))" : ""
    return "The author's notes (\(paragraphs.count) paragraphs):\n\n\(lines.joined(separator: "\n\n"))\(more)"
  }
}
