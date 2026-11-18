import ShadowCore
import Testing

@testable import NovelForgeCore

struct FinalizeReviewItemsParityTests {
  private static let fixture = Result { try FinalizeReviewFixture.load("items.json") }

  private func expectSameItems(_ entry: OrderedJSON, _ label: String) throws {
    let built = buildReviewItems(try fixtureMaterial(try entry.frField("material")))
    let expected = try entry.frField("items").frList
    #expect(built.map(\.itemKey) == expected.compactMap { $0["itemKey"]?.stringValue }, "\(label)")
    for (item, reference) in zip(built, expected) {
      #expect(reviewCanonical(item.proposedJSON) == reviewCanonical(reference), "\(label) \(item.itemKey)")
    }
  }

  @Test func shouldShareTheReferenceConstants() throws {
    let fixture = try Self.fixture.get()
    #expect(routineCategories == (try fixtureCategories(fixture["routine"])))
    #expect(FinalizeReviewItem.withheldEvidence.jsEquals(try fixture.frText("withheld")))
  }

  @Test func shouldBuildEveryTranscribedSpecCaseAsTheReference() throws {
    let cases = try Self.fixture.get().frField("spec").frList
    #expect(cases.count == 13)
    for entry in cases { try expectSameItems(entry, try entry.frText("name")) }
  }

  @Test func shouldBuildEveryGeneratedCaseAsTheReference() throws {
    let cases = try Self.fixture.get().frField("generated").frList
    #expect(cases.count == 80)
    for (index, entry) in cases.enumerated() { try expectSameItems(entry, "generated \(index)") }
  }
}
