import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

private enum ChunkerFixture {
  static let loaded: Result<JSONValue, any Error> = Result { try ReferenceFixture.decode(JSONValue.self, from: "retrieval/chunker.json") }

  static func cases() throws -> [JSONValue] {
    try loaded.get()["cases"].orThrow("cases").list()
  }
}

// A Swift String cannot hold a lone surrogate, so a cut through a surrogate pair drops its halves where JavaScript keeps them
private func removingLoneSurrogates(_ units: [UInt16]) -> [UInt16] {
  units.indices.compactMap { index in
    let unit = units[index]
    if UTF16.isLeadSurrogate(unit), index + 1 == units.count || !UTF16.isTrailSurrogate(units[index + 1]) { return nil }
    if UTF16.isTrailSurrogate(unit), index == 0 || !UTF16.isLeadSurrogate(units[index - 1]) { return nil }
    return unit
  }
}

// Fixtures/retrieval/generate.ts runs apps/novel-forge-server/src/modules/ai/retrieval/chunker.ts on every case
@Suite("Retrieval chunker parity", TestTimeLimit.quick)
struct RetrievalChunkerParityTests {
  @Test func shouldUseTheReferenceDefaultTarget() throws {
    #expect(try ChunkerFixture.loaded.get()["defaultTargetChars"].orThrow("defaultTargetChars").int() == RetrievalChunker.defaultTargetChars)
  }

  @Test func shouldChunkEveryCaseAsTheReferenceDoes() throws {
    let cases = try ChunkerFixture.cases()
    #expect(cases.count >= 440)
    let failed = try mismatches(cases) { row in
      let text = try row.at(0).string()
      let target = try row.at(1).optionalInt()
      let expected = try row.at(2).list().map { try $0.ints().map { UInt16(truncatingIfNeeded: $0) } }
      let actual = target.map { RetrievalChunker.chunk(text, targetChars: $0) } ?? RetrievalChunker.chunk(text)
      return actual.map { Array($0.utf16) } == expected.map(removingLoneSurrogates)
    }
    #expect(failed.isEmpty, "chunks differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldCoverCutsThroughSurrogatePairsAndChaptersLongerThanTheDefaultTarget() throws {
    let cases = try ChunkerFixture.cases()
    let cutPairs = try cases.filter { row in
      try row.at(2).list().contains { chunk in
        let units = try chunk.ints().map { UInt16(truncatingIfNeeded: $0) }
        return removingLoneSurrogates(units).count != units.count
      }
    }
    let longDefaults = try cases.filter { row in try row.at(1).isNull && row.at(2).list().count > 1 }
    #expect(!cutPairs.isEmpty)
    #expect(longDefaults.count >= 5)
  }

  @Test func shouldGiveOneEmptyChunkForEmptyText() {
    #expect(RetrievalChunker.chunk("") == [""])
  }
}
