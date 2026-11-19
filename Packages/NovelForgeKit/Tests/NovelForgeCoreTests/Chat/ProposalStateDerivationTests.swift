import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatWorld
private typealias Fixture = ProposalFixture

private func expectConsistent(_ reconciler: NovelForgeReconciler, in store: VaultStore) async throws {
  let comparison = try await Projection.compare(reconciler, in: store)
  #expect(comparison.incremental == comparison.rebuilt)
}

private func pending(_ novel: UUID, in store: VaultStore) async throws -> ChatPendingProposals {
  try await store.load(ChatPendingProposals.self, novel)
}

@Suite("Proposal state derivation", TestTimeLimit.standard)
struct ProposalStateDerivationTests {
  @Test func shouldListAStagedProposalAsPendingWithEveryIndexNotApplied() async throws {
    let (reconciler, store) = try World.store()
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: store)
    let state = try #require(try await World.proposalState(proposal.id, in: store))
    #expect(state.decision == .known(.pending) && state.rank == 0 && state.isPending)
    #expect(state.readability == .readable && state.operations == 4 && state.kind == .known(.chat))
    #expect(state.session == Fixture.session && state.message == Fixture.message && state.novel == Fixture.novel)
    #expect(state.counts == ProposalEntryCounts())
    #expect(try await World.entries(proposal.id, in: store) == Array(repeating: .notApplied, count: 4))
    #expect(try await pending(Fixture.novel, in: store).proposals.value?.map(\.proposal) == [proposal.id])
    #expect(try await pending(Fixture.novel, in: store).count == .available(1))
    #expect(try await pending(SchemaFixture.otherNovel, in: store).count == .available(0))
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldReadAppliedChangesActionsAndDeclinedIndexesAfterAnApply() async throws {
    let (reconciler, store) = try World.store()
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: store)
    try await World.apply(proposal, selected: [0, 3], in: store)
    let state = try #require(try await World.proposalState(proposal.id, in: store))
    #expect(state.decision == .known(.applied) && state.rank == 3 && !state.isPending)
    #expect(try await World.entries(proposal.id, in: store) == [.applied, .declined, .declined, .pending])
    #expect(state.counts == ProposalEntryCounts(applied: 1, pending: 1, declined: 2))
    let rows = try await Projection.fetch(ProposalChangeEntryDerivation.request(for: proposal.ref).order(Column("op")), in: store)
    #expect(rows.map(\.isAction) == [false, false, false, true] && rows.map(\.hasUndo) == [true, false, false, false])
    #expect(try await pending(Fixture.novel, in: store).count == .available(0))
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldFollowUndoRedoAndTheSettledOutcomeOfAnAction() async throws {
    let (reconciler, store) = try World.store()
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: store)
    try await World.apply(proposal, selected: [0, 1, 3], in: store)
    let content = try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 0)
    let action = try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 3)
    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.recordUndo(content, undoneState: Fixture.postState("p0"), in: &transaction) }
    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.settleAction(action, result: ProposalChangeResult(error: "no draft"), in: &transaction) }
    #expect(try await World.entries(proposal.id, in: store) == [.reverted, .applied, .declined, .failed])
    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.recordRedo(content, in: &transaction) }
    #expect(try await World.entries(proposal.id, in: store) == [.applied, .applied, .declined, .failed])
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldReadAnActionByItsResultWhenALaterApplierWritesPendingOverItsStatus() async throws {
    let (reconciler, store) = try World.store()
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: store)
    try await World.apply(proposal, selected: [3], in: store)
    let action = try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 3)
    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.settleAction(action, result: ProposalChangeResult(), in: &transaction) }
    try await Projection.set(action, ["status": "pending"], in: store)
    #expect(try await World.entries(proposal.id, in: store).last == .applied)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldShowAnUnreadableChangeAndAnUnknownStatusInsteadOfHidingThem() async throws {
    let (reconciler, store) = try World.store()
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: store)
    try await World.apply(proposal, selected: [0, 1], in: store)
    let first = try NovelForgeKey(novel: proposal.novel, .proposalChange(proposal: proposal.id, index: 0))
    let second = try NovelForgeKey(novel: proposal.novel, .proposalChange(proposal: proposal.id, index: 1))
    let stray = try NovelForgeKey(novel: proposal.novel, .proposalChange(proposal: proposal.id, index: 7))
    let foreign = try NovelForgeKey(novel: SchemaFixture.otherNovel, .proposalChange(proposal: proposal.id, index: 2))
    try await Projection.set(first.ref, ["status": .int(1)], in: store)
    try await Projection.set(second.ref, ["status": "dormant"], in: store)
    try await Projection.set(stray.ref, ["natural_key": stray.stored, "status": "applied"], in: store)
    try await Projection.set(foreign.ref, ["natural_key": foreign.stored, "status": "applied"], in: store)
    #expect(try await World.entries(proposal.id, in: store) == [.unreadable, .unrecognised, .declined, .declined])
    #expect(try await World.proposalState(proposal.id, in: store)?.counts == ProposalEntryCounts(declined: 2, unreadable: 2))
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldReadUnrecordedIndexesAsAwaitingWhenTheApplicationCannotBeRead() async throws {
    let (reconciler, store) = try World.store()
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: store)
    try await Projection.set(proposal.ref, ["decision": "applied", "applied": ["selected": "all"]], in: store)
    let state = try #require(try await World.proposalState(proposal.id, in: store))
    #expect(state.readability == .applicationUnreadable && state.decision == .known(.applied) && state.operations == 4)
    #expect(try await World.entries(proposal.id, in: store) == Array(repeating: .awaiting, count: 4))
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldKeepAProposalWhoseCardCannotBeReadWithItsDecisionAndNovel() async throws {
    let (reconciler, store) = try World.store()
    let ref = NovelForgeKey.proposal(SchemaFixture.proposal)
    try await Projection.set(ref, ["card": ["novel": Fixture.novel.json, "change_set": "later"], "decision": "pending"], in: store)
    let state = try #require(try await World.proposalState(SchemaFixture.proposal, in: store))
    #expect(state.readability == .cardUnreadable && state.operations == nil && state.kind == nil && state.isPending)
    #expect(try await World.entries(SchemaFixture.proposal, in: store).isEmpty)
    #expect(try await pending(Fixture.novel, in: store).proposals.value?.map(\.readability) == [.cardUnreadable])

    let anonymous = NovelForgeKey.proposal(SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000e1"))
    try await Projection.set(anonymous, ["card": .string("card"), "decision": "pending"], in: store)
    #expect(try await Projection.fetch(ProposalStateDerivation.request(for: anonymous), in: store).isEmpty)
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldGiveAMissingDecisionNoRankAndNeverListItAsPending() async throws {
    let (reconciler, store) = try World.store()
    let card = try Fixture.card()
    try await Projection.set(NovelForgeKey.proposal(SchemaFixture.proposal), ["card": card.json], in: store)
    let state = try #require(try await World.proposalState(SchemaFixture.proposal, in: store))
    #expect(state.decision == nil && state.rank == nil && !state.isPending && state.readability == .readable)
    #expect(try await pending(Fixture.novel, in: store).count == .available(0))
    try await expectConsistent(reconciler, in: store)
  }

  @Test func shouldWaitForTheProposalWhenItsChangesArriveFirst() async throws {
    let (reconciler, writer, reader) = (try World.reconciler(), try Projection.store(try World.reconciler()), try Projection.store(try World.reconciler()))
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: writer)
    try await World.apply(proposal, selected: [0, 2], in: writer)
    let lines = try await Projection.lines(of: writer)
    try await Projection.apply(Array(lines.dropFirst()), to: reader)
    #expect(try await World.proposalState(proposal.id, in: reader)?.decision == nil)
    try await expectConsistent(reconciler, in: reader)
    try await Projection.apply([lines[0]], to: reader)
    #expect(try await World.entries(proposal.id, in: reader) == [.applied, .declined, .applied, .declined])
    #expect(try await Projection.derived(reconciler, in: reader) == (try await Projection.derived(reconciler, in: writer)))
  }

  @Test func shouldListPendingProposalsOldestStagedFirst() async throws {
    let clock = SchemaTestClock()
    let reconciler = try World.reconciler()
    let store = try Projection.store(reconciler, clock: clock)
    let first = try Fixture.proposal(World.proposals[2])
    let second = try Fixture.proposal(World.proposals[0])
    let third = try Fixture.proposal(World.proposals[1])
    for proposal in [first, second, third] {
      try await World.stage(proposal, in: store)
      clock.advance()
    }
    try await World.dismiss(third.id, as: .superseded, in: store)
    #expect(try await pending(Fixture.novel, in: store).proposals.value?.map(\.proposal) == [first.id, second.id])
  }

  @Test func shouldReadTheDetailOfOneProposalAndReportItsFault() async throws {
    let (_, store) = try World.store()
    let proposal = try Fixture.proposal()
    try await World.stage(proposal, in: store)
    let detail = try #require(try await store.load(ChatProposal.self, proposal.id).proposal.value ?? nil)
    #expect(detail.state.proposal == proposal.id && detail.entries.map(\.index) == [0, 1, 2, 3])
    #expect(try await store.load(ChatProposal.self, SchemaFixture.proposal).proposal == .available(nil))

    let key = ProjectionFaults.key(proposal.ref)
    _ = try await store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT INTO nf_derived_fault (derivation, key, version, message) VALUES (?, ?, 1, 'broken')", arguments: [ProposalState.databaseTableName, key])
    }
    #expect(try await store.load(ChatProposal.self, proposal.id).proposal.isUnavailable)
    #expect(try await pending(Fixture.novel, in: store).faults.map(\.scope) == [.entry])
  }
}
