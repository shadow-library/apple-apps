import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

// Fixtures/bible-plan-handlers/merge.json: mergeBriefUpdate (apps/novel-forge-server/src/modules/refinement/brief-merge.ts:44) over plans it created and
// ops the change-set validator accepts, printed in the shape a captured plan inverse takes
@Suite("Plan merge parity")
struct PlanHandlerMergeParityTests {
  @Test func shouldMergeEveryPlanUpdateAsTheReferenceDoes() throws {
    let text = String(decoding: try ReferenceFixture.data("bible-plan-handlers/merge.json"), as: UTF8.self)
    let cases = try #require(try OrderedJSON(parsing: text).arrayValue)
    #expect(cases.count == 160)
    for (index, entry) in cases.enumerated() {
      let fixture = try #require(entry.objectValue)
      let op = try #require(fixture["op"]?.objectValue)
      let update = try briefUpdate(OrderedJSON.object(op).jsonText)
      var existing: ChapterPlanContent?
      if let stored = fixture["existing"]?.objectValue {
        guard case .brief(let restore) = try PlanRestore(stored) else { throw PlanHandlerTestError.notABriefUpdate("case \(index)") }
        existing = restore.restoring(over: ChapterPlanContent(body: ""))
      }
      let defaults = try #require(fixture["defaults"]?.objectValue)
      let given = PlanDefaults(volume: defaults["volumeKey"]?.stringValue, contentMode: defaults["contentMode"]?.stringValue.map(StoredEnum.init(rawValue:)))
      let merged = PlanBriefMerge.merged(existing, update, defaults: given)
      let expected = try #require(fixture["expected"]?.objectValue)
      #expect(BriefRestore(merged, chapter: update.chapter).json == expected, "case \(index)")
    }
  }
}
