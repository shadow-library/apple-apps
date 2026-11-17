import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let heir = KnowledgeReveal(entityKey: "mara", factKey: "heir")
private let crown = KnowledgeReveal(entityKey: "mara", factKey: "crown")

private func approval(_ number: UInt8) -> UUID {
  UUID(uuid: (0xD2, 0x5B, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, number))
}

private func lifecycle(_ scenario: DomainScenario, chapter: Int, on index: Int) async throws -> ChapterLifecycleEntry? {
  try await ChapterTables.lifecycle(scenario.novel, in: await scenario.store(index))[chapter]
}

private func ledger(_ scenario: DomainScenario, on index: Int) async throws -> Set<LedgerView> {
  Set(try await scenario.fetch(CharacterKnowledgeDerivation.request(for: scenario.novel), on: index).map(LedgerView.init))
}

@Suite("Domain oracle gaps", .timeLimit(.minutes(2)))
struct DomainOracleScenarioTests {
  @Test func shouldTeachAFactBehindAMilestoneOnceAnotherDeviceFinalizesAChapterClaimingIt() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25B_0001)
    let unlock = JSONValue.object(["all": .array([.object(["milestone": .string("rise")])])])
    try await scenario.on(0) { transaction, novel in
      try Secrets.upsert(novel: novel, secret: "crown", text: "The crown is false.", SecretChanges(unlock: .set(unlock)), in: &transaction)
    }
    try await scenario.plan(1, on: 0, claims: ["rise"])
    try await scenario.draft(1, on: 0)
    try await scenario.plan(2, on: 0, learns: [crown])
    try await scenario.draft(2, on: 0)
    try await scenario.settle()
    let status = { (index: Int) async throws -> PlanRevealStatus? in
      try await scenario.fetch(PlanRevealDerivation.request(for: scenario.novel), on: index).first { $0.chapter == 2 }?.status
    }
    for index in 0..<3 { #expect(try await status(index) == .holds) }

    try await scenario.plan(1, on: 1, claims: [])
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await status(index) == .violated)
      #expect(try await lifecycle(scenario, chapter: 2, on: index)?.stale?.code == "reveal")
    }

    try await scenario.plan(1, on: 1, claims: ["rise"])
    try await scenario.approve(1, on: 1, id: approval(1))
    try await scenario.finalize(1, on: 1)
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await status(index) == .holds)
      #expect(try await lifecycle(scenario, chapter: 2, on: index)?.stale == nil)
    }

    try await scenario.approve(2, on: 2, id: approval(2))
    try await scenario.settle()
    for index in 0..<3 { #expect(try await ledger(scenario, on: index) == [LedgerView("crown", "mara", 2, .brief, .provisional)]) }
    try await scenario.finalize(2, on: 0)
    try await scenario.settle()
    for index in 0..<3 { #expect(try await ledger(scenario, on: index) == [LedgerView("crown", "mara", 2, .brief, .committed)]) }
  }

  @Test func shouldLabelAnEntryWithTheEarliestOfTwoWithdrawalsMadeOnDifferentDevices() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25B_0003)
    let novel = scenario.novel
    let original = try await scenario.store(0).read { transaction in try NotebookLedger.load(novel: novel, in: transaction).entries[0].id }
    let (first, second) = (UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001")!, UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
    try await scenario.on(1) { transaction, novel in
      _ = try NotebookWithdrawalRecord(id: first, novel: novel, entry: original, reason: "Not the tone.").append(in: &transaction)
    }
    await scenario.replicas.advanceClock(of: 2, by: .seconds(3000))
    try await scenario.on(2) { transaction, novel in
      _ = try NotebookWithdrawalRecord(id: second, novel: novel, entry: original, reason: "Too bleak.").append(in: &transaction)
    }
    try await scenario.settle()
    for index in 0..<3 {
      let states = try await scenario.fetch(NotebookEntryStateRow.filter(Column("novel") == novel), on: index)
      #expect(states.first { $0.entry == original }?.withdrawal == first)
    }
  }

  @Test func shouldKeepAFactBehindAMilestoneHiddenUntilItsRevealChapterEvenOnceTheMilestoneIsReached() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25B_0008)
    let unlock = JSONValue.object(["all": .array([.object(["milestone": .string("rise")])])])
    try await scenario.on(0) { transaction, novel in
      try Secrets.upsert(novel: novel, secret: "crown", text: "The crown is false.", SecretChanges(unlock: .set(unlock)), in: &transaction)
    }
    try await scenario.plan(1, on: 0, claims: ["rise"])
    try await scenario.draft(1, on: 0)
    try await scenario.plan(2, on: 0, learns: [crown])
    try await scenario.draft(2, on: 0)
    try await scenario.settle()
    let status = { (index: Int) async throws -> PlanRevealStatus? in
      try await scenario.fetch(PlanRevealDerivation.request(for: scenario.novel), on: index).first { $0.chapter == 2 }?.status
    }
    for index in 0..<3 { #expect(try await status(index) == .holds) }
    try await scenario.on(1) { transaction, novel in
      try Secrets.upsert(novel: novel, secret: "crown", text: "The crown is false.", SecretChanges(revealChapter: .set(4)), in: &transaction)
    }
    try await scenario.settle()
    for index in 0..<3 { #expect(try await status(index) == .violated) }
  }

  @Test func shouldNotCountAMilestoneAChapterReachesForAChapterBeforeIt() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25B_0009)
    let unlock = JSONValue.object(["all": .array([.object(["milestone": .string("rise")])])])
    try await scenario.on(0) { transaction, novel in
      try Secrets.upsert(novel: novel, secret: "crown", text: "The crown is false.", SecretChanges(unlock: .set(unlock)), in: &transaction)
    }
    try await scenario.plan(1, on: 0, claims: ["rise"])
    try await scenario.draft(1, on: 0)
    try await scenario.plan(2, on: 0, learns: [crown])
    try await scenario.draft(2, on: 0)
    try await scenario.replicas.settle()
    try await scenario.approve(1, on: 1, id: approval(11))
    try await scenario.approve(2, on: 1, id: approval(12))
    try await scenario.replicas.settle()

    try await scenario.plan(1, on: 0, claims: [])
    try await scenario.approve(1, on: 0, id: approval(13))
    try await scenario.finalize(1, on: 0)
    await scenario.replicas.advanceClock(of: 1, by: .seconds(9000))
    try await scenario.finalize(1, on: 1)
    try await scenario.finalize(2, on: 1)
    try await scenario.replicas.settle()
    try await scenario.plan(3, on: 2, claims: ["rise"])
    try await scenario.draft(3, on: 2)
    try await scenario.approve(3, on: 2, id: approval(14))
    try await scenario.finalize(3, on: 2)
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await scenario.fetch(FinalChapterEntry.all(), on: index).map(\.chapter).sorted() == [1, 2, 3])
      #expect(try await scenario.fetch(FinalChapterEntry.all(), on: index).first { $0.chapter == 1 }?.approval == approval(13))
      #expect(try await scenario.fetch(MilestoneStateDerivation.request(for: scenario.novel), on: index).first { $0.milestone == "rise" }?.reachedChapter == 3)
      #expect(try await ledger(scenario, on: index).isEmpty)
    }
  }

  @Test func shouldMarkAnAcceptedDraftAgainWhenTheAncestorChangesAfterTheAcceptance() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25B_0004)
    for chapter in 1...2 {
      try await scenario.plan(chapter, on: 0)
      try await scenario.draft(chapter, on: 0)
    }
    try await scenario.replicas.settle()
    try await scenario.draft(1, on: 2, "The tide turns back.")
    try await scenario.settle()
    let novel = scenario.novel
    let seen = try await lifecycle(scenario, chapter: 2, on: 1)?.stale ?? .unrecorded
    let revision = try await scenario.head(2, on: 1) ?? ""
    try await scenario.store(1).approveChapter(novel: novel, chapter: 2, revision: revision, as: .asWritten(seen: seen), id: approval(3))
    try await scenario.replicas.collect(1)
    try await scenario.settle()
    for index in 0..<3 {
      let accepted = try await lifecycle(scenario, chapter: 2, on: index)
      #expect(accepted?.stale == nil && accepted?.differences != nil && accepted?.approval == approval(3))
    }
    let before = try await lifecycle(scenario, chapter: 2, on: 0)?.differences
    try await scenario.draft(1, on: 0, "The tide turns back again.")
    try await scenario.settle()
    for index in 0..<3 {
      let again = try await lifecycle(scenario, chapter: 2, on: index)
      #expect(again?.stale == .ancestorDraft(chapter: 1, change: .rewritten(source: DraftSource.handEdited.rawValue)))
      #expect(again?.approval == nil && again?.differences != before)
    }
  }

  @Test func shouldNameAFinalizedAncestorWhenItWasFinalizedFromAnotherRevisionThanTheDraftRestsOn() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25B_0006)
    try await scenario.plan(1, on: 0)
    try await scenario.draft(1, on: 0)
    try await scenario.draft(2, on: 0)
    try await scenario.replicas.settle()
    try await scenario.draft(1, on: 1, "The tide turns back.")
    try await scenario.approve(1, on: 1, id: approval(4))
    try await scenario.finalize(1, on: 1)
    try await scenario.settle()
    for index in 0..<3 { #expect(try await lifecycle(scenario, chapter: 2, on: index)?.stale == .ancestorDraft(chapter: 1, change: .finalized)) }
  }

  @Test func shouldNameALostApprovalWhenAnAncestorStopsTeachingWhatItsPlanStillTeaches() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25B_0007)
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.approve(1, on: 0, id: approval(5))
    try await scenario.draft(2, on: 0)
    try await scenario.settle()
    #expect(try await lifecycle(scenario, chapter: 2, on: 1)?.stale == nil)
    try await scenario.on(1) { transaction, novel in
      try Secrets.upsert(novel: novel, secret: "heir", text: "Mara is the heir.", SecretChanges(revealChapter: .set(4)), in: &transaction)
    }
    try await scenario.settle()
    for index in 0..<3 { #expect(try await lifecycle(scenario, chapter: 2, on: index)?.stale == .ancestorKnowledge(chapter: 1, lost: true)) }
  }
}
