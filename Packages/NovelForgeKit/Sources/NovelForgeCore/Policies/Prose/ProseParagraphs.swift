/// `start` is the first non-blank character and `end` is just past the last, in UTF-16 code units of the text it was read from.
struct ProseParagraph: Equatable, Sendable {
  let start: Int
  let end: Int
}

// packages/sdk/src/prose-paragraphs.ts:150
func proseParagraphs(_ text: String) -> [ProseParagraph] {
  ProseScanner.shared?.paragraphs(in: text) ?? []
}

// packages/sdk/src/prose-paragraphs.ts:164
func paragraphNumberAt(_ paragraphs: [ProseParagraph], offset: Int) -> Int {
  guard let found = paragraphs.firstIndex(where: { $0.end > offset }) else { return max(paragraphs.count, 1) }
  return found + 1
}

// packages/sdk/src/prose-paragraphs.ts:169
func paragraphAt(_ text: String, offset: Int) -> Int {
  paragraphNumberAt(proseParagraphs(text), offset: offset)
}
