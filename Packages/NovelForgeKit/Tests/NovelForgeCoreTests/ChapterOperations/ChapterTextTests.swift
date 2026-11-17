import Foundation
import Testing

@testable import NovelForgeCore

private struct ComposeCase: Decodable {
  let body: String
  let scenes: [BriefScene]
  let expected: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    body = try container.decode(String.self)
    scenes = try container.decode([BriefScene].self)
    expected = try container.decode(String.self)
  }
}

@Suite("Chapter text rules")
struct ChapterTextTests {
  @Test func shouldComposePlanBodiesAsTheReferenceDoes() throws {
    let cases = try ReferenceFixture.decode([ComposeCase].self, from: "chapter-operations/compose.json")
    #expect(cases.count == 400)
    for (index, sample) in cases.enumerated() {
      let composed = composePlanBody(sample.body, scenes: sample.scenes)
      #expect(Array(composed.utf16) == Array(sample.expected.utf16), "case \(index)")
    }
  }

  @Test func shouldNormalizeEveryLineEndingToANewline() {
    #expect(normalizeLineEndings("a\r\nb\rc\nd\r\r\n") == "a\nb\nc\nd\n\n")
    #expect(Array(normalizeLineEndings("e\u{301}\r\n").unicodeScalars) == Array("e\u{301}\n".unicodeScalars))
  }

  @Test func shouldEndASentenceOnlyWhereItDoesNotEndAlready() {
    #expect(asSentence("  a \t b  ") == "a b.")
    #expect(asSentence("Why?") == "Why?")
    #expect(asSentence("he said ”") == "he said ”")
    #expect(asSentence("") == ".")
  }
}
