import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let other = SchemaFixture.otherNovel

private struct Book {
  let store: VaultStore

  static func make(milestones: [String] = ["rise", "fall"]) async throws -> Book {
    let book = Book(store: try Projection.store(try Projection.reconciler()))
    try await book.run { transaction in
      for key in milestones { try PlanWorldWrites.milestone(novel: novel, key, in: &transaction) }
    }
    return book
  }

  func run(_ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
    try await Projection.write(store, body)
  }

  func plan(_ chapter: Int, claims: [String], of owner: UUID = novel) async throws {
    try await run { try PlanWorldWrites.putPlan(novel: owner, chapter: chapter, planContent(contract(claims: claims)), in: &$0) }
  }

  func finalize(_ chapter: Int, claims: [String]) async throws {
    try await run { try PlanWorldWrites.finalize(novel: novel, chapter: chapter, contract(claims: claims), in: &$0) }
  }

  func claims(of owner: UUID = novel) async throws -> Set<Claim> {
    try await PlanWorldTables.claims(owner, in: store)
  }

  func milestones(of owner: UUID = novel) async throws -> [String: MilestoneSnapshot] {
    try await PlanWorldTables.milestones(owner, in: store)
  }
}

@Suite("Milestone claims and state", .timeLimit(.minutes(2)))
struct MilestoneDerivationTests {
  @Test
  func shouldLeaveAnUnclaimedMilestoneOpen() async throws {
    let book = try await Book.make()
    #expect(try await book.claims().isEmpty)
    #expect(try await book.milestones() == ["rise": MilestoneSnapshot("open"), "fall": MilestoneSnapshot("open")])
  }

  @Test
  func shouldLetTheEarliestPlanHoldAndFlagEveryLaterClaim() async throws {
    let book = try await Book.make()
    try await book.plan(4, claims: ["rise"])
    try await book.plan(2, claims: ["rise", "fall"])
    try await book.plan(3, claims: ["rise"])
    #expect(
      try await book.claims() == [
        Claim("rise", 2, .holds, holder: 2), Claim("rise", 3, .duplicate, holder: 2), Claim("rise", 4, .duplicate, holder: 2), Claim("fall", 2, .holds, holder: 2),
      ])
    #expect(try await book.milestones() == ["rise": MilestoneSnapshot("planned", planned: 2), "fall": MilestoneSnapshot("planned", planned: 2)])
    try await book.plan(2, claims: [])
    #expect(try await book.claims() == [Claim("rise", 3, .holds, holder: 3), Claim("rise", 4, .duplicate, holder: 3)])
    #expect(try await book.milestones() == ["rise": MilestoneSnapshot("planned", planned: 3), "fall": MilestoneSnapshot("open")])
  }

  @Test
  func shouldListAClaimOncePerChapter() async throws {
    let book = try await Book.make()
    try await book.plan(1, claims: ["rise", "rise"])
    #expect(try await book.claims() == [Claim("rise", 1, .holds, holder: 1)])
  }

  @Test
  func shouldReachAMilestoneWhenAFinalChaptersCanonClaimsIt() async throws {
    let book = try await Book.make()
    try await book.plan(1, claims: ["rise"])
    try await book.plan(3, claims: ["rise"])
    try await book.finalize(1, claims: ["rise"])
    #expect(try await book.milestones()["rise"] == MilestoneSnapshot("reached", planned: 1, reached: 1))
    #expect(try await book.claims() == [Claim("rise", 1, .canon, .holds, holder: 1), Claim("rise", 3, .duplicate, holder: 1)])
  }

  @Test
  func shouldKeepTheCanonsClaimWhenTheFinalChaptersPlanChangesLater() async throws {
    let book = try await Book.make()
    try await book.finalize(1, claims: ["rise"])
    try await book.plan(1, claims: ["fall"])
    #expect(try await book.claims() == [Claim("rise", 1, .canon, .holds, holder: 1)])
    #expect(try await book.milestones() == ["rise": MilestoneSnapshot("reached", planned: 1, reached: 1), "fall": MilestoneSnapshot("open")])
  }

  @Test
  func shouldLetACanonsClaimOutrankAnEarlierPlansClaim() async throws {
    let book = try await Book.make()
    try await book.plan(1, claims: ["rise"])
    try await book.finalize(2, claims: ["rise"])
    try await book.finalize(3, claims: ["rise"])
    #expect(
      try await book.claims() == [Claim("rise", 1, .duplicate, holder: 2), Claim("rise", 2, .canon, .holds, holder: 2), Claim("rise", 3, .canon, .duplicate, holder: 2)])
    #expect(try await book.milestones()["rise"] == MilestoneSnapshot("reached", planned: 2, reached: 2))
  }

  @Test
  func shouldFlagAClaimOfARemovedMilestoneAsUnknownUntilItIsRestored() async throws {
    let book = try await Book.make()
    try await book.plan(1, claims: ["rise", "ghost"])
    try await book.run { _ = try MilestoneRecord.remove(novel: novel, milestone: "rise", in: &$0) }
    #expect(try await book.claims() == [Claim("rise", 1, .unknown), Claim("ghost", 1, .unknown)])
    #expect(try await book.milestones() == ["fall": MilestoneSnapshot("open")])
    try await book.run { _ = try MilestoneRecord(novel: novel, milestone: "rise", label: "Milestone rise").restore(in: &$0) }
    #expect(try await book.claims() == [Claim("rise", 1, .holds, holder: 1), Claim("ghost", 1, .unknown)])
    #expect(try await book.milestones()["rise"] == MilestoneSnapshot("planned", planned: 1))
  }

  @Test
  func shouldKeepAMilestoneItCannotReadAndDropAPurgedOne() async throws {
    let book = try await Book.make()
    try await book.plan(1, claims: ["rise", "fall"])
    try await book.run { _ = try $0.set(MilestoneRecord.ref(novel: novel, milestone: "rise"), ["label": .int(1)]) }
    try await book.run { _ = try $0.purge(MilestoneRecord.ref(novel: novel, milestone: "fall")) }
    #expect(try await book.claims() == [Claim("rise", 1, .holds, holder: 1), Claim("fall", 1, .unknown)])
    #expect(try await book.milestones() == ["rise": MilestoneSnapshot("planned", planned: 1)])
  }

  @Test
  func shouldIgnoreRemovedAndUnreadablePlansAndKeepNovelsApart() async throws {
    let book = try await Book.make()
    try await book.plan(1, claims: ["rise"])
    try await book.plan(2, claims: ["fall"])
    try await book.plan(1, claims: ["rise"], of: other)
    try await book.run { _ = try ChapterPlanRecord.remove(try ChapterPlanRecord.ref(novel: novel, chapter: 1), in: &$0) }
    try await book.run { _ = try $0.revise(try ChapterPlanRecord.ref(novel: novel, chapter: 2), body: .object(["body": .int(1)])) }
    #expect(try await book.claims().isEmpty)
    #expect(try await book.milestones() == ["rise": MilestoneSnapshot("open"), "fall": MilestoneSnapshot("open")])
    #expect(try await book.claims(of: other) == [Claim("rise", 1, .unknown)])
    #expect(try await book.milestones(of: other).isEmpty)
  }

  @Test
  func shouldMatchADecomposedClaimToItsMilestone() async throws {
    let book = try await Book.make(milestones: ["r\u{E9}ve"])
    try await book.plan(1, claims: ["re\u{301}ve"])
    #expect(try await book.claims() == [Claim("r\u{E9}ve", 1, .holds, holder: 1)])
  }
}
