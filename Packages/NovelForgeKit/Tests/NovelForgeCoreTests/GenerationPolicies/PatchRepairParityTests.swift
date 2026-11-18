import Testing

@testable import NovelForgeCore

struct PatchRepairParityTests {
  private struct PatchFixture: Decodable {
    let find: String
    let replace: String

    var patch: ProsePatch { ProsePatch(find: find, replace: replace) }
  }

  private struct ProposalFixture: Decodable {
    let action: String
    let body: String?
    let patches: [PatchFixture]?

    var proposal: RepairProposal { RepairProposal(action: RepairMode(rawValue: action) ?? .rewrite, body: body, patches: patches?.map(\.patch)) }
  }

  private struct Rejection: Decodable {
    let patch: Int
    let occurrences: Int
  }

  private struct Outcome: Decodable {
    let kind: String
    let prose: String?
    let attemptBumped: Bool
    let keepsFindings: Bool
    let rejection: Rejection?
  }

  private struct ResolveCase: Decodable {
    let prose: String
    let proposal: ProposalFixture
    let outcome: Outcome
  }

  private struct DollarCase: Decodable {
    let prose: String
    let patch: PatchFixture
    let referenceProse: String
    let literalProse: String
  }

  private struct EmptyAnchorCase: Decodable {
    let prose: String
    let referenceProse: String?
  }

  private struct SourceCase: Decodable {
    let attempt: Int
    let repairMode: String
    let source: String
  }

  private struct Cases: Decodable {
    let resolve: [ResolveCase]
    let dollars: [DollarCase]
    let emptyAnchors: [EmptyAnchorCase]
    let sources: [SourceCase]
  }

  private func load() throws -> Cases { try GenerationFixtures.load("patches") }

  @Test func shouldMatchTheReferenceRepairResolution() throws {
    let cases = try load().resolve
    #expect(cases.count > 30)
    var kinds = Set<String>()
    for (index, row) in cases.enumerated() {
      let outcome = PatchRepair.resolve(row.proposal.proposal, prose: row.prose)
      kinds.insert(row.outcome.kind)
      switch outcome {
      case .rewriteBody(let body):
        #expect(row.outcome.kind == "rewriteBody" && row.outcome.prose == body, "case \(index)")
        #expect(!row.outcome.attemptBumped && !row.outcome.keepsFindings, "case \(index)")
      case .patched(let prose):
        #expect(row.outcome.kind == "patched" && row.outcome.prose == prose, "case \(index)")
        #expect(row.outcome.attemptBumped && row.outcome.keepsFindings, "case \(index)")
      case .fallBackToRewrite(let rejection):
        #expect(row.outcome.kind == "fallBack" && row.outcome.prose == nil, "case \(index)")
        #expect(!row.outcome.attemptBumped && !row.outcome.keepsFindings, "case \(index)")
        guard let expected = row.outcome.rejection else {
          #expect(rejection == nil, "case \(index)")
          continue
        }
        let reason = try #require(rejection, "case \(index)")
        switch reason {
        case .emptyAnchor(let patch): #expect(expected.occurrences == -1 && expected.patch == patch, "case \(index)")
        case .anchorNotFound(let patch): #expect(expected.occurrences == 0 && expected.patch == patch, "case \(index)")
        case .anchorAmbiguous(let patch, let occurrences): #expect(expected.occurrences == occurrences && expected.patch == patch && occurrences > 1, "case \(index)")
        }
      }
    }
    #expect(kinds == ["rewriteBody", "patched", "fallBack"])
  }

  @Test func shouldApplyReplacementTextLiterally() throws {
    let cases = try load().dollars
    #expect(cases.count == 5)
    for (index, row) in cases.enumerated() {
      #expect(try PatchRepair.apply([row.patch.patch], to: row.prose) == row.literalProse, "case \(index)")
    }
    #expect(cases.filter { $0.referenceProse != $0.literalProse }.count == 4)
  }

  @Test func shouldRefuseAnEmptyAnchorTheReferenceAppliesToATwoUnitBody() throws {
    let cases = try load().emptyAnchors
    #expect(cases.contains { $0.referenceProse == "xab" })
    for row in cases {
      #expect(throws: PatchRejection.emptyAnchor(patch: 0)) { try PatchRepair.apply([ProsePatch(find: "", replace: "x")], to: row.prose) }
    }
  }

  @Test func shouldNameTheRevisionSourceLikeTheReference() throws {
    let cases = try load().sources
    #expect(cases.count == 8)
    for row in cases { #expect(RevisionSource.named(attempt: row.attempt, repairMode: RepairMode(rawValue: row.repairMode) ?? .rewrite).rawValue == row.source) }
  }

  @Test func shouldReportWhichAnchorBrokeThePatch() {
    let prose = "one two two three"
    #expect(throws: PatchRejection.anchorAmbiguous(patch: 1, occurrences: 2)) {
      try PatchRepair.apply([ProsePatch(find: "one", replace: "1"), ProsePatch(find: "two", replace: "2")], to: prose)
    }
    #expect(throws: PatchRejection.anchorNotFound(patch: 0)) { try PatchRepair.apply([ProsePatch(find: "four", replace: "4")], to: prose) }
  }
}
