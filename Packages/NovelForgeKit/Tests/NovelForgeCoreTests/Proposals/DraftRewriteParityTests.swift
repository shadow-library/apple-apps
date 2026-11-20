import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

// Fixtures/draft-handlers/rewrites.json: rewrittenBody (apps/novel-forge-server/src/modules/refinement/passage-rewrite.ts:190) over anchors the
// reference stamped, then moved, edited, duplicated, stripped or replaced
@Suite("Passage rewrite parity")
struct DraftRewriteParityTests {
  @Test func shouldWriteEveryBodyAndRefuseEveryRewriteAsTheReferenceDoes() throws {
    let text = String(decoding: try ReferenceFixture.data("draft-handlers/rewrites.json"), as: UTF8.self)
    let cases = try #require(try OrderedJSON(parsing: text).arrayValue)
    #expect(cases.count == 260)
    for (index, entry) in cases.enumerated() {
      let fixture = try #require(entry.objectValue)
      let body = try #require(fixture["body"]?.stringValue)
      let draftId = try #require(fixture["draftId"]?.stringValue)
      let records = try #require(fixture["rewrites"]?.arrayValue)
      let rewrites = records.compactMap { $0.objectValue.flatMap { DraftRewritePassage(OpFields(record: $0)) } }
      try #require(rewrites.count == records.count, "case \(index)")
      let expected = try #require(fixture["expected"]?.objectValue)
      do {
        let written = try PassageRewrite.rewrittenBody(body, draftId: draftId, chapter: 3, rewrites)
        let want = try #require(expected["body"]?.stringValue, "case \(index) wrote \(written.debugDescription)")
        #expect(written.jsEquals(want), "case \(index)")
      } catch let refusal as ApplyRefusal {
        #expect(expected["code"]?.stringValue == refusal.code, "case \(index)")
        #expect(expected["message"]?.stringValue.map { $0.jsEquals(refusal.errorDescription ?? "") } == true, "case \(index): \(refusal)")
      }
    }
  }
}
