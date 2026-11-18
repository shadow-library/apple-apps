import ShadowCore
import Testing

@testable import NovelForgeCore

struct FinalizeReviewGateParityTests {
  private static let fixture = Result { try FinalizeReviewFixture.load("gate.json") }

  private func snapshot(_ json: OrderedJSON) throws -> FinalizeReviewSnapshot {
    FinalizeReviewSnapshot(
      draftRevision: String(try json.frInt("draftRevision")), sourceHash: try json.frText("sourceHash"),
      status: try FinalizeReviewStatus(rawValue: try json.frText("status")).orThrow("status"), items: try json.frField("items").frList.map(fixtureReviewItem))
  }

  /// The reference refuses or not as recorded, except that a revision without a review refuses as still preparing (decision 2) where it returns null or FRV_004.
  private func expectSameRefusal(_ entry: OrderedJSON, _ label: String) throws -> String? {
    let draftJSON = try entry.frField("draft")
    let draft = ReviewedRevision(revision: String(try draftJSON.frInt("revision")), body: try draftJSON.frText("body"))
    let reviews = try entry.frField("reviews").frList.map(snapshot)
    let refusal = reviewRefusal(reviews, draft)
    guard reviews.contains(where: { $0.draftRevision == draft.revision }) else {
      #expect(refusal == .preparing, "\(label)")
      return nil
    }
    let expected = try entry.frField("refusal")
    if expected.frIsNull {
      #expect(refusal == nil, "\(label)")
    } else {
      #expect(refusal?.code == (try expected.frText("code")), "\(label)")
      #expect(refusal?.errorDescription?.jsEquals(try expected.frText("message")) == true, "\(label) \(String(describing: refusal))")
    }
    return refusal?.code ?? "none"
  }

  @Test func shouldRefuseEveryTranscribedSpecCaseAsTheReference() throws {
    let cases = try Self.fixture.get().frField("spec").frList
    #expect(cases.count == 13)
    let compared = try cases.compactMap { try expectSameRefusal($0, try $0.frText("name")) }
    #expect(compared == ["FRV_004", "none", "FRV_005", "FRV_002", "FRV_006", "none", "FRV_006", "FRV_006", "none", "FRV_003", "none"])
  }

  @Test func shouldRefuseEveryGeneratedCaseAsTheReference() throws {
    let cases = try Self.fixture.get().frField("generated").frList
    #expect(cases.count == 120)
    let codes = Set(try cases.enumerated().compactMap { index, entry in try expectSameRefusal(entry, "generated \(index)") })
    #expect(codes == ["none", "FRV_002", "FRV_003", "FRV_004", "FRV_005", "FRV_006"])
  }

  @Test func shouldReadUnreachedClaimsStrandedRevealsAndOpenItemsAsTheReference() throws {
    let cases = try Self.fixture.get().frField("lists").frList
    #expect(cases.count == 100)
    for (index, entry) in cases.enumerated() {
      let items = try entry.frField("items").frList.enumerated().map { index, json in
        var item = try fixtureReviewItem(json)
        item.claim = String(index)
        return item
      }
      let indices = { (selected: [FinalizeReviewItem]) in selected.compactMap { Int($0.claim) } }
      #expect(indices(unreachedClaims(items)) == (try entry.frField("unreached").frList.map { Int($0.numberValue ?? -1) }), "unreached \(index)")
      #expect(indices(openItems(items)) == (try entry.frField("open").frList.map { Int($0.numberValue ?? -1) }), "open \(index)")
      let stranded = try entry.frField("stranded")
      #expect(
        strandedReveals(items) == (stranded.frIsNull ? nil : StrandedReveal(milestone: try stranded.frText("milestone"), facts: try stranded.frField("facts").frTexts)),
        "stranded \(index)")
      for (item, effective) in zip(items, try entry.frField("effective").frList) {
        #expect(reviewCanonical(effectiveChange(item).json) == reviewCanonical(effective), "effective \(index) \(item.itemKey)")
      }
    }
  }

  @Test func shouldRefuseAsStillPreparingWhileTheApprovedRevisionHasNoReview() {
    let draft = ReviewedRevision(revision: "rev-3", body: "Mira climbs.")
    let older = FinalizeReviewSnapshot(draftRevision: "rev-2", sourceHash: reviewedBodyHash("Mira climbs."), status: .ready, items: [])
    #expect(reviewRefusal([], draft) == .preparing)
    #expect(reviewRefusal([older], draft) == .preparing)
    #expect(reviewRefusal([FinalizeReviewSnapshot(draftRevision: "rev-3", sourceHash: reviewedBodyHash("Mira climbs."), status: .ready, items: [])], draft) == nil)
  }
}
