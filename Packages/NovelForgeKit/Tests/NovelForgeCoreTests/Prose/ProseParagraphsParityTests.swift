import Testing

@testable import NovelForgeCore

private struct ParagraphCase: Decodable {
  let text: String
  let spans: [[Int]]
  let numbers: [[Int]]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    text = try container.decode(String.self)
    spans = try container.decode([[Int]].self)
    numbers = try container.decode([[Int]].self)
  }
}

private struct ParagraphFixture: Decodable {
  let cases: [ParagraphCase]
}

struct ProseParagraphsParityTests {
  private static func load() throws -> [ParagraphCase] {
    try ReferenceFixture.decode(ParagraphFixture.self, from: "prose/paragraphs.json").cases
  }

  @Test func shouldCarryAtLeastAThousandCases() throws {
    let cases = try Self.load()
    #expect(cases.count >= 1000)
    #expect(cases.contains { $0.spans.isEmpty } && cases.contains { $0.spans.count >= 4 })
  }

  @Test func shouldFindTheReferenceBlocksInEveryCase() throws {
    let mismatches = try Self.load().filter { reference in
      proseParagraphs(reference.text).map { [$0.start, $0.end] } != reference.spans
    }
    #expect(mismatches.map(\.text) == [])
  }

  @Test func shouldNumberEveryReferenceOffsetAsTheReferenceDoes() throws {
    let mismatches = try Self.load().filter { reference in
      let paragraphs = proseParagraphs(reference.text)
      return reference.numbers.contains { paragraphNumberAt(paragraphs, offset: $0[0]) != $0[1] || paragraphAt(reference.text, offset: $0[0]) != $0[1] }
    }
    #expect(mismatches.map(\.text) == [])
  }
}
