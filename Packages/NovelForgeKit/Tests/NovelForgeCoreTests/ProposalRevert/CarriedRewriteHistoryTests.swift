import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

/// Three rewrites of chapter 1 applied by two concurrent appliers: the first selected [0, 1] (0 leads, 1 carried), the second [1, 2] (1 leads, 2 carried).
/// The merged records hold an undo on 0 and 1 (the first-writer-wins `undo` of 1 is the second applier's), none on 2, which either may have carried.
private func unionOfTwoAppliers(in store: VaultStore) async throws -> (proposal: ProposalRecord, first: ProposalChangeRecord, merged: ProposalChangeRecord) {
  let ops = try csOps(
    #"[{"op":"draft.rewrite_passage","chapter":1,"passage":"He was afraid of her.","replacement":"His grip went damp."},"#
      + #"{"op":"draft.rewrite_passage","chapter":1,"passage":"He worked his wrist.","replacement":"He flexed his wrist."},"#
      + #"{"op":"draft.rewrite_passage","chapter":1,"passage":"She left.","replacement":"She went."}]"#)
  let base = try ProposalFixture.card()
  let proposal = ProposalRecord(
    id: UUID(), card: try ProposalCard(novel: base.novel, session: base.session, kind: base.kind, summary: base.summary, changeSet: ops, baseline: base.baseline))
  try await ChatWorld.stage(proposal, in: store)
  let first = try ProposalFixture.change(of: proposal, 0, undo: try ProposalFixture.undo("p-0"))
  let merged = try ProposalFixture.change(of: proposal, 1, undo: try ProposalFixture.undo("p-1"))
  let carried = try ProposalFixture.change(of: proposal, 2)
  _ = try await Projection.write(store) { transaction in
    try ProposalRecord.recordApply(proposal.ref, changes: [first, merged], postState: ProposalFixture.postState("p1"), automatic: false, in: &transaction)
  }
  _ = try await Projection.write(store) { transaction in try carried.create(in: &transaction) }
  return (proposal, first, merged)
}

private func historyChange(in store: VaultStore) async throws -> ChatChange {
  try #require(try await store.load(ChatChangeHistory.self, ChatChangeHistoryQuery(novel: ChatOperationsWorld.novel)).page.value?.changes.first)
}

// CarriedRewrites over the changes every applier recorded, not the first applier's selection alone
@Suite("Carried rewrites in the change history", TestTimeLimit.standard)
struct CarriedRewriteHistoryTests {
  @Test func shouldCarryASecondAppliersRewriteByEveryChangeThatMayHaveCarriedIt() async throws {
    let store = try await ChatOperationsWorld.store()
    let (_, first, merged) = try await unionOfTwoAppliers(in: store)
    var change = try await historyChange(in: store)
    #expect(change.entries.map(\.carriers) == [[], [], [0, 1]] && change.entries.map(\.carriedBy) == [nil, nil, nil])
    #expect(change.entries.map(\.state) == [.applied, .applied, .applied] && change.isRevertible && !change.isReverted)

    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.recordUndo(first.ref, undoneState: ProposalFixture.postState("p0"), in: &transaction) }
    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.recordUndo(merged.ref, undoneState: ProposalFixture.postState("p0"), in: &transaction) }

    change = try await historyChange(in: store)
    #expect(change.entries.map(\.state) == [.reverted, .reverted, .reverted] && change.entries.map { $0.row.state } == [.reverted, .reverted, .applied])
    #expect(change.isReverted && !change.isRevertible)
  }

  @Test func shouldReadARewriteWhoseCarriersStandInAMixAsUncertain() async throws {
    let store = try await ChatOperationsWorld.store()
    let (_, first, _) = try await unionOfTwoAppliers(in: store)
    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.recordUndo(first.ref, undoneState: ProposalFixture.postState("p0"), in: &transaction) }

    let change = try await historyChange(in: store)

    #expect(change.entries.map(\.state) == [.reverted, .applied, .uncertain])
    #expect(!change.isReverted && change.isRevertible)
  }

  @Test func shouldStandACarriedRewriteAsItsCarriersAgreeAndUncertainOtherwise() {
    let standing = { (states: [ProposalChangeEntryState]) in CarriedRewrites.standing(of: states, applied: .applied, reverted: .reverted, uncertain: .uncertain) }
    #expect(standing([.unreadable]) == .unreadable)
    #expect(standing([.applied, .applied]) == .applied)
    #expect(standing([.reverted, .reverted]) == .reverted)
    #expect(standing([.reverted, .applied]) == .uncertain)
    #expect(standing([.reverted, .unreadable]) == .uncertain)
    #expect(standing([]) == .uncertain)
  }

  // A redo of a leader replays only the rewrites it alone may have carried
  @Test func shouldNotReplayARewriteSeveralChangesMayHaveCarried() async throws {
    let store = try await ChatOperationsWorld.store()
    let (proposal, first, merged) = try await unionOfTwoAppliers(in: store)
    let carried = try ProposalFixture.change(of: proposal, 2)
    let union = ProposalTurn(proposal: proposal, entries: [.recorded(first), .recorded(merged), .recorded(carried)])
    #expect(union.carried(by: 0).isEmpty && union.carried(by: 1).isEmpty)

    let alone = ProposalTurn(proposal: proposal, entries: [.recorded(first), .recorded(try ProposalFixture.change(of: proposal, 1)), .declined])
    #expect(alone.carried(by: 0) == [1])
  }
}
