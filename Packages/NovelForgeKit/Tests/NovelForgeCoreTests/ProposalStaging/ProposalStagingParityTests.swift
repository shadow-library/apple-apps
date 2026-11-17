import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

private struct StagingFixture {
  let anchors: [OrderedJSONObject]
  let apart: [OrderedJSONObject]
  let echoes: [OrderedJSONObject]
  let clears: [OrderedJSONObject]

  static func load() throws -> StagingFixture {
    let text = String(decoding: try ReferenceFixture.data("proposal-staging/staging.json"), as: UTF8.self)
    let root = try #require(try OrderedJSON(parsing: text).objectValue)
    func section(_ name: String) throws -> [OrderedJSONObject] {
      let items = try #require(root[name]?.arrayValue)
      return try items.map { try #require($0.objectValue) }
    }
    return StagingFixture(anchors: try section("anchors"), apart: try section("apart"), echoes: try section("echoes"), clears: try section("clears"))
  }
}

private func ops(_ value: OrderedJSON?) throws -> [ChangeOp] {
  try parseChangeSet(try #require(value), options: ChangeSetValidationOptions(entityMaterialization: false))
}

private func drafts(_ value: OrderedJSON?, cursor: Int = 0) throws -> [Int: AnchorDraft] {
  var drafts = [Int: AnchorDraft]()
  for item in try #require(value?.arrayValue) {
    let row = try #require(item.objectValue)
    let chapter = try #require(number(row["chapter"]))
    drafts[chapter] = AnchorDraft(
      id: try #require(row["id"]?.stringValue), revision: try #require(number(row["revision"])),
      saveSeq: try #require(number(row["saveSeq"])), body: try #require(row["body"]?.stringValue),
      isolated: row["isolated"] == .bool(true), locked: chapter <= cursor || row["status"]?.stringValue == "final")
  }
  return drafts
}

private func number(_ value: OrderedJSON?) -> Int? {
  value?.numberValue.flatMap { Int(exactly: $0) }
}

private func texts(_ value: OrderedJSON?) throws -> [String] {
  try #require(value?.arrayValue).map { try #require($0.stringValue) }
}

// Fixtures/proposal-staging/staging.json, from apps/novel-forge-server/src/modules/refinement/passage-rewrite.ts and proposal-warnings.ts
@Suite("Proposal staging parity")
struct ProposalStagingParityTests {
  // passage-rewrite.ts:176 (stampPassageAnchors)
  @Test func shouldAnchorEveryRewriteOrRefuseTheChangeSetAsTheReferenceDoes() throws {
    let fixture = try StagingFixture.load()
    #expect(fixture.anchors.count == 220)
    var reasons = Set<RewriteDropReason>()
    for (index, entry) in fixture.anchors.enumerated() {
      let cursor = try #require(number(entry["cursor"]))
      let given = try ops(entry["ops"])
      let standing = try drafts(entry["drafts"], cursor: cursor)
      let expected = try #require(entry["expected"]?.objectValue)
      let want = expected["ops"]?.arrayValue
      do throws(ProposalStagingError) {
        let stamped = try PassageAnchoring.stamp(given, drafts: standing)
        #expect(want != nil, "case \(index) anchored what the reference refused")
        #expect(stamped.map { OrderedJSON.object($0.fields).storable } == (want ?? []).map(\.storable), "case \(index)")
      } catch {
        #expect(expected["code"]?.stringValue == error.code, "case \(index): \(error)")
        if case .rewriteNotPlaced(_, let reason) = error { reasons.insert(reason) }
      }
    }
    #expect(reasons == [.noDraft, .locked, .isolated, .wholeChapter, .tooLong, .notFound, .ambiguous, .unchanged])
  }

  // passage-rewrite.ts:223 (rewritesApart)
  @Test func shouldTellCardsApartByTheirStandingPassagesAsTheReferenceDoes() throws {
    let fixture = try StagingFixture.load()
    #expect(fixture.apart.count == 100)
    for (index, entry) in fixture.apart.enumerated() {
      let verdict = PassageAnchoring.rewritesApart(
        older: try ops(entry["older"]), newer: try ops(entry["newer"]), shared: try texts(entry["shared"]), drafts: try drafts(entry["drafts"]))
      #expect(.bool(verdict) == entry["expected"], "case \(index)")
    }
  }

  // proposal-warnings.ts:82 (negationEchoWarnings)
  @Test func shouldWarnOfEveryNegationEchoAsTheReferenceDoes() throws {
    let fixture = try StagingFixture.load()
    #expect(fixture.echoes.count == 160)
    for (index, entry) in fixture.echoes.enumerated() {
      var baselines = BaselineTexts()
      for member in try #require(entry["baselines"]?.objectValue).entries {
        let fields = try #require(member.value.objectValue)
        baselines[JSString(member.key)] = Dictionary(uniqueKeysWithValues: fields.entries.map { ($0.key, $0.value.stringValue) })
      }
      let warnings = try #require(ProposalWarnings.negationEchoes(try ops(entry["ops"]), baselines: baselines))
      #expect(sameTexts(warnings, try texts(entry["expected"])), "case \(index): \(warnings)")
    }
  }

  // proposal-warnings.ts:109 (revealClearWarnings)
  @Test func shouldWarnOfEveryClearedRevealDateAsTheReferenceDoes() throws {
    let fixture = try StagingFixture.load()
    #expect(fixture.clears.count == 60)
    for (index, entry) in fixture.clears.enumerated() {
      var dated = [JSString: Int]()
      for member in try #require(entry["dated"]?.objectValue).entries {
        let chapter: Int = try #require(number(member.value))
        dated[JSString(member.key)] = chapter
      }
      let warnings = ProposalWarnings.revealClears(try ops(entry["ops"]), datedFacts: dated)
      #expect(sameTexts(warnings, try texts(entry["expected"])), "case \(index): \(warnings)")
    }
  }
}
