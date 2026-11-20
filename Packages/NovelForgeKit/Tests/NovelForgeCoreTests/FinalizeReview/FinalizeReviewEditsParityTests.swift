import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

struct FinalizeReviewEditsParityTests {
  private static let fixture = Result { try FinalizeReviewFixture.load("edits.json") }

  private func expectSameEdit(_ entry: OrderedJSON, _ label: String) throws {
    let proposed = try fixtureProposal(try entry.frField("proposed"))
    let patch = try (try entry.frField("patch")).objectValue.orThrow("patch")
    let result = try entry.frField("result")
    #expect(proposed.itemKey.jsEquals(try entry.frText("itemKey")), "\(label)")
    #expect(reviewCanonical(proposed.json) == reviewCanonical(try entry.frField("proposed")), "\(label) round trip")
    switch Result(catching: { () throws(FinalizeReviewError) -> ProposedChange in try editedChange(proposed, patch) }) {
    case .success(let change):
      #expect(reviewCanonical(change.json) == reviewCanonical(try result.frField("change")), "\(label) \(patch.entries.map(\.key))")
    case .failure(let error):
      guard case .editRefused(let refusal) = error else { throw FixtureShapeError(description: "\(label) \(error)") }
      #expect(refusal.reason.jsEquals(try result.frText("refused")), "\(label) \(refusal)")
      #expect(error.code == "FRV_009")
      #expect(error.errorDescription?.jsEquals(try entry.frText("message")) == true, "\(label)")
    }
  }

  @Test func shouldEditTheTranscribedSpecProposalAsTheReference() throws {
    let cases = try Self.fixture.get().frField("spec").frList
    #expect(cases.count == 2)
    for (index, entry) in cases.enumerated() { try expectSameEdit(entry, "spec \(index)") }
  }

  @Test func shouldEditEveryGeneratedProposalAsTheReference() throws {
    let cases = try Self.fixture.get().frField("edits").frList
    #expect(cases.count == 350)
    for (index, entry) in cases.enumerated() { try expectSameEdit(entry, "edit \(index)") }
  }

  @Test func shouldCompareProposalsAsTheReferenceThroughTheirDigests() throws {
    let cases = try Self.fixture.get().frField("same").frList
    #expect(cases.count == 200)
    for (index, entry) in cases.enumerated() {
      let left = try fixtureProposal(try entry.frField("left"))
      let right = try fixtureProposal(try entry.frField("right"))
      let same = try entry.frFlag("same")
      #expect(sameProposal(left, right) == same, "same \(index)")
      #expect((left.digest == right.digest) == same, "digest \(index)")
    }
  }

  @Test func shouldKeepEveryRoutineCategoryUntilTheAuthorChooses() throws {
    for entry in try Self.fixture.get().frField("autoKeep").frList {
      let chosen = try entry.frField("chosen")
      let expected = try fixtureCategories(entry["expected"])
      #expect(effectiveAutoKeep(chosen.frIsNull ? nil : try fixtureCategories(chosen)) == expected, "\(chosen.jsonText)")
    }
  }

  @Test func shouldRefuseAFieldNamedAfterAnObjectPrototypeMember() throws {
    let state = ProposedChange.characterState(.init(entityKey: "mira", location: "the tower", evidence: "Mira climbs"))
    for field in ["constructor", "toString", "hasOwnProperty", "__proto__"] {
      #expect(throws: FinalizeReviewError.editRefused(.notEditable(field: field))) {
        try editedChange(state, OrderedJSONObject([(key: field, value: .string("x"))]))
      }
    }
  }

  @Test func shouldDigestAProposalFromItsContentAlone() throws {
    let ordered = try fixtureProposal(try OrderedJSON(parsing: #"{"category":"relationship","relationship":{"entityKey":"mira","targetKey":"oren","kind":"ally","evidence":"x"}}"#))
    let reversed = try fixtureProposal(
      try OrderedJSON(parsing: #"{"relationship":{"evidence":"x","kind":"ally","targetKey":"oren","entityKey":"mira"},"category":"relationship"}"#))
    #expect(ordered.digest == reversed.digest)
    #expect(ordered.digest.count == 64)
    #expect(ProposedChange.summary(text: "caf\u{e9}").digest != ProposedChange.summary(text: "cafe\u{301}").digest)
    #expect(ProposedChange.characterState(.init(entityKey: "mira", conditions: [], evidence: "x")) != ProposedChange.characterState(.init(entityKey: "mira", evidence: "x")))
  }
}
