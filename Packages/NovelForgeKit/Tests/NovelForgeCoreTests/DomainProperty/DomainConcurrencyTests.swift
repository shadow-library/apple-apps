import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let heir = KnowledgeReveal(entityKey: "mara", factKey: "heir")

private func approval(_ number: UInt8) -> UUID {
  UUID(uuid: (0xD2, 0x50, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, number))
}

private func ledger(_ scenario: DomainScenario, on index: Int) async throws -> Set<LedgerView> {
  Set(try await scenario.fetch(CharacterKnowledgeDerivation.request(for: scenario.novel), on: index).map(LedgerView.init))
}

@Suite("Domain operations racing on three devices", TestTimeLimit.property)
struct DomainConcurrencyTests {
  @Test func shouldKeepTheFirstCanonAndCommitItsKnowledgeOnceWhenTwoDevicesFinalizeTheSameChapter() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1001)
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    let (first, second) = (approval(1), approval(2))
    try await scenario.approve(1, on: 1, id: first)
    try await scenario.finalize(1, on: 1)
    await scenario.replicas.advanceClock(of: 2, by: .seconds(60))
    try await scenario.approve(1, on: 2, id: second)
    try await scenario.finalize(1, on: 2)
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await scenario.fetch(FinalChapterEntry.all(), on: index).map(\.approval) == [first])
      #expect(try await scenario.fetch(StoryCursor.all(), on: index).map(\.chapter) == [2])
      #expect(try await ledger(scenario, on: index) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    }
    await scenario.expectRefused(.draftFinal(1), on: 2) { transaction, novel in try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &transaction) }
  }

  @Test func shouldHoldTheLaterOfTwoApprovalsOfOneHeadAndBindItWhenTheChapterIsFinalized() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1010)
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    let (early, late) = (approval(3), approval(4))
    try await scenario.approve(1, on: 1, id: early)
    await scenario.replicas.advanceClock(of: 2, by: .seconds(60))
    try await scenario.approve(1, on: 2, id: late)
    try await scenario.settle()
    for index in 0..<3 { #expect(try await scenario.fetch(ApprovalInForceDerivation.request(for: scenario.novel), on: index).map(\.approval) == [late]) }
    try await scenario.finalize(1, on: 0)
    try await scenario.settle()
    #expect(try await scenario.fetch(FinalChapterEntry.all(), on: 1).map(\.approval) == [late])
  }

  @Test func shouldDropAnApprovalWhenAnotherDeviceChangesWhatThePlanTeachesButKeepItForAnEditOfTheProse() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1002)
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    let kept = approval(5)
    try await scenario.approve(1, on: 1, id: kept)
    try await scenario.plan(1, on: 2, learns: [heir], body: "The plan, reworded.")
    try await scenario.settle()
    #expect(try await scenario.fetch(ApprovalInForceDerivation.request(for: scenario.novel), on: 0).map(\.approval) == [kept])

    try await scenario.approve(1, on: 1, id: approval(6))
    try await scenario.plan(1, on: 2, learns: [heir, KnowledgeReveal(entityKey: "oren", factKey: "heir")])
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await scenario.fetch(ApprovalInForceDerivation.request(for: scenario.novel), on: index).isEmpty)
      #expect(try await ChapterTables.lifecycle(scenario.novel, in: await scenario.store(index))[1]?.review == .needsReview)
    }
    await scenario.expectRefused(.draftNotApproved(1), on: 1) { transaction, novel in try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &transaction) }
  }

  @Test func shouldRevokeALaterChaptersApprovalWhenAnotherDeviceRewritesTheChapterItRestsOn() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1011)
    for chapter in 1...2 {
      try await scenario.plan(chapter, on: 0, learns: [heir])
      try await scenario.draft(chapter, on: 0)
    }
    try await scenario.replicas.settle()
    try await scenario.approve(2, on: 1, id: approval(7))
    try await scenario.draft(1, on: 2, "The tide turns back.")
    try await scenario.settle()
    let novel = scenario.novel
    for index in 0..<3 {
      let entry = try await ChapterTables.lifecycle(novel, in: await scenario.store(index))[2]
      let rewritten = StaleCause.ancestorDraft(chapter: 1, change: .rewritten(source: DraftSource.handEdited.rawValue))
      #expect(entry?.stale == rewritten)
      #expect(entry?.approval == nil)
      #expect(try await scenario.fetch(ApprovalInForceDerivation.request(for: novel), on: index).isEmpty)
    }
    let seen = try await ChapterTables.lifecycle(novel, in: await scenario.store(1))[2]?.stale ?? .unrecorded
    let revision = try await scenario.head(2, on: 1) ?? ""
    let kept = approval(8)
    try await scenario.store(1).approveChapter(novel: novel, chapter: 2, revision: revision, as: .asWritten(seen: seen), id: kept)
    try await scenario.replicas.collect(1)
    try await scenario.settle()
    #expect(try await scenario.fetch(ApprovalInForceDerivation.request(for: novel), on: 2).map(\.approval) == [kept])
    let accepted = try await ChapterTables.lifecycle(novel, in: await scenario.store(0))[2]
    #expect(accepted?.stale == nil && accepted?.differences != nil)
    await scenario.expectRefused(.finalizeOutOfOrder(2), on: 2) { transaction, novel in try ChapterFinalize.finalize(novel: novel, chapter: 2, in: &transaction) }
  }

  @Test func shouldHoldNoApprovalOfAHeadThatAnotherDeviceRevisedMeanwhile() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1003)
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    try await scenario.approve(1, on: 1, id: approval(9))
    let revised = try await scenario.draft(1, on: 2, "The tide turns back.")
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await scenario.head(1, on: index) == revised)
      #expect(try await scenario.fetch(ApprovalInForceDerivation.request(for: scenario.novel), on: index).isEmpty)
      #expect(try await ledger(scenario, on: index).isEmpty)
    }
    await scenario.expectRefused(.draftNotApproved(1), on: 1) { transaction, novel in try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &transaction) }
  }

  @Test func shouldKeepARemovalOverAConcurrentEditAndHideWhatTheRemovedRecordCarried() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1004)
    try await scenario.on(0) { transaction, novel in
      try ManualReveals.reveal(novel: novel, secret: "heir", entity: "oren", chapter: 1, in: &transaction)
      _ = try Pages.save(novel: novel, section: .world, slug: "harbour", body: "Salt and rope.", in: &transaction)
    }
    try await scenario.replicas.settle()
    try await scenario.on(1) { transaction, novel in
      try Entities.remove(novel: novel, entity: "oren", in: &transaction)
      try Pages.remove(novel: novel, section: .world, slug: "harbour", in: &transaction)
    }
    try await scenario.on(2) { transaction, novel in
      try Entities.edit(novel: novel, entity: "oren", name: "Oren the Elder", in: &transaction)
      _ = try Pages.revise(novel: novel, section: .world, slug: "harbour", body: "Salt, rope and tar.", in: &transaction)
    }
    try await scenario.settle()
    let novel = scenario.novel
    for index in 0..<3 {
      let (entity, page) = try await scenario.store(index).read { transaction in
        (try Entities.get(novel: novel, entity: "oren", in: transaction), try Pages.get(novel: novel, section: .world, slug: "harbour", in: transaction))
      }
      #expect(entity == nil && page == nil)
      #expect(try await ledger(scenario, on: index).isEmpty)
    }
    try await scenario.on(0) { transaction, novel in
      try Entities.restore(novel: novel, entity: "oren", in: &transaction)
      try Pages.restore(novel: novel, section: .world, slug: "harbour", in: &transaction)
    }
    try await scenario.settle()
    let restored = try await scenario.store(1).read { transaction in
      (try Entities.get(novel: novel, entity: "oren", in: transaction)?.name, try Pages.get(novel: novel, section: .world, slug: "harbour", in: transaction)?.content.body)
    }
    #expect(restored.0 == "Oren the Elder" && restored.1 == "Salt, rope and tar.")
    #expect(try await ledger(scenario, on: 1) == [LedgerView("heir", "oren", 1, .manual, .committed)])
  }

  @Test func shouldGiveEveryEntryOneSuccessorWhenDevicesSupersedeAnEntryAndItsRewriteConcurrently() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1005)
    let original = try await scenario.on(0) { transaction, novel in
      try Notebook.recordByAuthor(AuthorNotebookEntry(kind: .direction, topic: "plot.tone", statement: "Keep it bleak."), novel: novel, in: &transaction).id
    }
    try await scenario.replicas.settle()
    let rewrite = NotebookRewrite(statement: "Keep it bleak, then warm.")
    let early = try await scenario.on(0) { transaction, novel in try Notebook.supersedeByAuthor(original, rewrite: rewrite, novel: novel, in: &transaction).id }
    try await scenario.replicas.deliver(from: 0, to: 2)
    await scenario.replicas.advanceClock(of: 1, by: .seconds(2000))
    await scenario.replicas.advanceClock(of: 2, by: .seconds(3000))
    let late = try await scenario.on(1) { transaction, novel in try Notebook.supersedeByAuthor(original, rewrite: rewrite, novel: novel, in: &transaction).id }
    let chained = try await scenario.on(2) { transaction, novel in try Notebook.supersedeByAuthor(early, rewrite: rewrite, novel: novel, in: &transaction).id }
    try await scenario.settle()
    for index in 0..<3 {
      let states = Dictionary(
        uniqueKeysWithValues: try await scenario.fetch(NotebookEntryStateRow.filter(Column("novel") == scenario.novel), on: index).map { ($0.entry, $0) })
      #expect(states[original]?.successor == late && states[original]?.status == .superseded)
      #expect(states[early]?.successor == chained && states[early]?.status == .superseded)
      #expect(states[late]?.status == .active && states[chained]?.status == .active)
    }
  }

  @Test func shouldHoldTheEarliestClaimAndFlagTheOtherWhenTwoDevicesClaimOneMilestone() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1006)
    try await scenario.plan(2, on: 1, claims: ["rise"])
    try await scenario.plan(1, on: 2, claims: ["rise"])
    try await scenario.settle()
    let novel = scenario.novel
    for index in 0..<3 {
      let claims = try await scenario.fetch(MilestoneClaimDerivation.request(for: novel), on: index).map { "\($0.chapter) \($0.status.rawValue) \(String(describing: $0.holder))" }
      #expect(Set(claims) == ["1 holds Optional(1)", "2 duplicate Optional(1)"])
      let structure = try await scenario.store(index).load(StoryStructure.self, novel)
      #expect(structure.milestones.value?.items.map(\.duplicateClaims) == [[2]])
    }
  }

  @Test func shouldResolveRivalEndingsPlannedOnTwoDevicesToTheLatestAndFlagTheOther() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1007)
    try await scenario.plan(2, on: 1, ending: true)
    try await scenario.plan(3, on: 2, ending: true)
    try await scenario.settle()
    for index in 0..<3 {
      let rivals = try await scenario.fetch(PlanRevealDerivation.request(for: scenario.novel), on: index).map { "\($0.chapter) \(String(describing: $0.rivalEnding))" }
      #expect(Set(rivals) == ["2 Optional(3)", "3 nil"])
    }
    await scenario.expectRefused(.endingPlanned(3), on: 0) { transaction, novel in
      var edit = PlanEdit(body: "Another end.")
      edit.isEnding = .set(true)
      try ChapterPlans.write(novel: novel, chapter: 4, edit, in: &transaction)
    }
  }

  @Test func shouldPlaceTheCursorBeforeAGapUntilTheEarlierFinalArrives() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1008, order: .writerOrderOnly)
    try await scenario.plan(1, on: 0)
    try await scenario.draft(1, on: 0)
    try await scenario.approve(1, on: 0, id: approval(10))
    try await scenario.finalize(1, on: 0)
    try await scenario.replicas.deliver(from: 0, to: 1)
    try await scenario.plan(2, on: 1)
    try await scenario.draft(2, on: 1)
    try await scenario.approve(2, on: 1, id: approval(11))
    try await scenario.finalize(2, on: 1)
    try await scenario.replicas.deliver(from: 1, to: 2)
    #expect(try await scenario.fetch(FinalChapterEntry.all(), on: 2).map(\.chapter) == [2])
    #expect(try await scenario.fetch(StoryCursor.all(), on: 2).map(\.chapter) == [1])
    try await DomainProperty.expectRebuilt(scenario.reconciler, replica: 2, in: scenario.replicas)
    try await scenario.settle()
    #expect(try await scenario.fetch(StoryCursor.all(), on: 2).map(\.chapter) == [3])
  }

  @Test func shouldHideAPairTheAuthorRetractedOnOneDeviceWhileAnotherFinalizedAChapterTeachingIt() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1012)
    try await scenario.on(0) { transaction, novel in try ManualReveals.reveal(novel: novel, secret: "heir", entity: "mara", chapter: 1, in: &transaction) }
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    try await scenario.on(1) { transaction, novel in try ManualReveals.retract(novel: novel, secret: "heir", entity: "mara", in: &transaction) }
    try await scenario.approve(1, on: 2, id: approval(12))
    try await scenario.finalize(1, on: 2)
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await scenario.fetch(FinalChapterEntry.all(), on: index).count == 1)
      #expect(try await ledger(scenario, on: index).isEmpty)
    }
  }

  @Test func shouldCommitNoKnowledgeOfAFactCreatedAfterTheApprovalTheCanonBinds() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1009)
    try await scenario.plan(1, on: 0, learns: [heir, KnowledgeReveal(entityKey: "mara", factKey: "crown")])
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    try await scenario.approve(1, on: 1, id: approval(13))
    await scenario.replicas.advanceClock(of: 2, by: .seconds(3000))
    try await scenario.on(2) { transaction, novel in
      try Secrets.upsert(novel: novel, secret: "crown", text: "The crown is false.", SecretChanges(revealChapter: .set(1)), in: &transaction)
    }
    try await scenario.replicas.settle()
    try await scenario.finalize(1, on: 1)
    try await scenario.settle()
    for index in 0..<3 { #expect(try await ledger(scenario, on: index) == [LedgerView("heir", "mara", 1, .brief, .committed)]) }
  }

  @Test func shouldBindTheApprovalInForceWhenALaterApprovalOfTheHeadNoLongerMatchesThePlan() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1013)
    let wider = [heir, KnowledgeReveal(entityKey: "oren", factKey: "heir")]
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.approve(1, on: 0, id: approval(31))
    try await scenario.plan(1, on: 0, learns: wider)
    try await scenario.approve(1, on: 0, id: approval(32))
    try await scenario.replicas.settle()
    try await scenario.plan(1, on: 1, learns: [heir])
    try await scenario.replicas.settle()
    #expect(try await scenario.fetch(ApprovalInForceDerivation.request(for: scenario.novel), on: 2).map(\.approval) == [approval(31)])
    try await scenario.finalize(1, on: 2)
    try await scenario.settle()
    #expect(try await scenario.fetch(FinalChapterEntry.all(), on: 0).map(\.approval) == [approval(31)])
  }

  @Test func shouldMarkADraftWrittenOnACanonThatLostAConcurrentFinalize() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1014)
    try await scenario.plan(1, on: 0)
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    try await scenario.approve(1, on: 1, id: approval(41))
    try await scenario.finalize(1, on: 1)
    await scenario.replicas.advanceClock(of: 2, by: .seconds(60))
    try await scenario.approve(1, on: 2, id: approval(42))
    try await scenario.finalize(1, on: 2)
    try await scenario.draft(2, on: 2)
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await scenario.fetch(FinalChapterEntry.all(), on: index).map(\.approval) == [approval(41)])
      #expect(try await ChapterTables.lifecycle(scenario.novel, in: await scenario.store(index))[2]?.stale == .canonReplaced(chapter: 1))
    }
  }

  @Test func shouldMarkALaterDraftWhenAnotherDeviceChangesWhatAnApprovedEarlierChapterTeaches() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1015)
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.approve(1, on: 0, id: approval(51))
    try await scenario.draft(2, on: 0)
    try await scenario.replicas.settle()
    try await scenario.plan(1, on: 1, learns: [heir, KnowledgeReveal(entityKey: "oren", factKey: "heir")])
    try await scenario.settle()
    for index in 0..<3 {
      let stale = try await ChapterTables.lifecycle(scenario.novel, in: await scenario.store(index))[2]?.stale
      #expect(stale == .ancestorKnowledge(chapter: 1, lost: false))
    }
  }

  @Test func shouldMarkAPlanAndItsDraftWhenAnotherDeviceMovesTheRevealOfAFactItTeachesLater() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1016)
    try await scenario.plan(1, on: 0, learns: [heir])
    try await scenario.draft(1, on: 0)
    try await scenario.replicas.settle()
    try await scenario.on(1) { transaction, novel in
      try Secrets.upsert(novel: novel, secret: "heir", text: "Mara is the heir.", SecretChanges(revealChapter: .set(4)), in: &transaction)
    }
    try await scenario.settle()
    for index in 0..<3 {
      #expect(try await scenario.fetch(PlanRevealDerivation.request(for: scenario.novel), on: index).map(\.status) == [.violated])
      #expect(try await ChapterTables.lifecycle(scenario.novel, in: await scenario.store(index))[1]?.stale?.code == "reveal")
    }
  }

  @Test func shouldOrderVolumesByOrdinalThenKeyWhenDevicesTieAndReorderThem() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1017)
    try await scenario.on(1) { transaction, novel in try Volumes.create(novel: novel, volume: "two", ordinal: 1, in: &transaction) }
    try await scenario.settle()
    let states = { (index: Int) async throws -> [String: VolumeState] in
      Dictionary(uniqueKeysWithValues: try await scenario.fetch(VolumeStateEntry.filter(Column("novel") == scenario.novel), on: index).map { ($0.volume, $0.state) })
    }
    for index in 0..<3 { #expect(try await states(index) == ["one": .active, "two": .notStarted]) }
    try await scenario.on(2) { transaction, novel in try Volumes.edit(novel: novel, volume: "one", VolumeChanges(ordinal: .set(2)), in: &transaction) }
    try await scenario.settle()
    for index in 0..<3 { #expect(try await states(index) == ["one": .notStarted, "two": .active]) }
  }

  @Test func shouldLabelAnEntryWithdrawnOnOneDeviceWhileAnotherSupersededIt() async throws {
    let scenario = try await DomainScenario.make(seed: 0xD25_1018)
    let novel = scenario.novel
    let original = try await scenario.store(0).read { transaction in try NotebookLedger.load(novel: novel, in: transaction).entries[0].id }
    let rewrite = try await scenario.on(1) { transaction, novel in
      try Notebook.supersedeByAuthor(original, rewrite: NotebookRewrite(statement: "Keep it bleak, then warm."), novel: novel, in: &transaction).id
    }
    try await scenario.on(2) { transaction, novel in _ = try Notebook.withdraw(original, reason: "Not the tone.", novel: novel, in: &transaction) }
    try await scenario.settle()
    for index in 0..<3 {
      let states = Dictionary(
        uniqueKeysWithValues: try await scenario.fetch(NotebookEntryStateRow.filter(Column("novel") == novel), on: index).map { ($0.entry, $0) })
      #expect(states[original]?.status == .withdrawn && states[original]?.successor == rewrite)
      #expect(states[rewrite]?.status == .active)
    }
  }
}
