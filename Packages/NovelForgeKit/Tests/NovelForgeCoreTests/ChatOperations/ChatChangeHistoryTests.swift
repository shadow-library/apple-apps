import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatOperationsWorld

private func history(offset: Int = 0, limit: Int = 30, in store: VaultStore) async throws -> ChatChangePage {
  try #require(try await store.load(ChatChangeHistory.self, ChatChangeHistoryQuery(novel: World.novel, offset: offset, limit: limit)).page.value)
}

private func applied(_ selected: [Int] = [0, 1, 3], session: UUID = ProposalFixture.session, in store: VaultStore) async throws -> ProposalRecord {
  let card = try ProposalFixture.card()
  let proposal = ProposalRecord(
    id: UUID(),
    card: try ProposalCard(
      novel: card.novel, session: session, message: card.message, kind: card.kind, summary: card.summary, changeSet: card.changeSet.compactMap(\.op),
      baseline: card.baseline))
  try await ChatWorld.stage(proposal, in: store)
  try await ChatWorld.apply(proposal, selected: selected, in: store)
  return proposal
}

/// Two passage rewrites of chapter 1, the second carried by the first, and one of chapter 2.
private func rewriteCard() throws -> ProposalRecord {
  let ops = try csOps(
    #"[{"op":"draft.rewrite_passage","chapter":1,"passage":"He was afraid of her.","replacement":"His grip went damp."},"#
      + #"{"op":"draft.rewrite_passage","chapter":1,"passage":"He worked his wrist.","replacement":"He flexed his wrist."},"#
      + #"{"op":"draft.rewrite_passage","chapter":2,"passage":"She left.","replacement":"She went."}]"#)
  let base = try ProposalFixture.card()
  return ProposalRecord(
    id: UUID(), card: try ProposalCard(novel: base.novel, session: base.session, kind: base.kind, summary: base.summary, changeSet: ops, baseline: base.baseline))
}

/// The changes `ProposalApply` records for the whole card: each chapter's leader holds the undo, the carried rewrite none.
private func rewriteChanges(of proposal: ProposalRecord) throws -> [ProposalChangeRecord] {
  [
    try ProposalFixture.change(of: proposal, 0, undo: try ProposalFixture.undo("p-0")), try ProposalFixture.change(of: proposal, 1),
    try ProposalFixture.change(of: proposal, 2, undo: try ProposalFixture.undo("p-2")),
  ]
}

private func rewrites(in store: VaultStore) async throws -> ProposalRecord {
  let proposal = try rewriteCard()
  try await ChatWorld.stage(proposal, in: store)
  let changes = try rewriteChanges(of: proposal)
  _ = try await Projection.write(store) { transaction in
    try ProposalRecord.recordApply(proposal.ref, changes: changes, postState: ProposalFixture.postState("p1"), automatic: false, in: &transaction)
  }
  return proposal
}

/// The history rows a settled replica must hold, read from the raw proposal states alone.
private func expectedHistory(in store: VaultStore) async throws -> [ProposalHistoryRow] {
  try await store.read { transaction in
    try transaction.states(ofKind: NovelForgeKind.proposal.entityKind, scope: .vault).compactMap { ref, state -> ProposalHistoryRow? in
      guard case .record(let record) = state, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key,
        record[field: "decision"]?.value == "applied", let novel = record[field: "card"]?.value["novel"].flatMap(UUID.init(json:))
      else { return nil }
      let applied = record[field: "applied"].flatMap { $0.value.isNull ? nil : $0.clock } ?? record[field: "decision"]?.clock
      return applied.map { ProposalHistoryRow(proposal: id, novel: novel, applied: $0) }
    }.sorted { $0.proposal.uuidString < $1.proposal.uuidString }
  }
}

@Suite("Change history", TestTimeLimit.standard)
struct ChatChangeHistoryTests {
  @Test func shouldListAppliedProposalsNewestApplyFirstWithEveryChange() async throws {
    let store = try await World.store()
    let first = try await applied(in: store)
    let second = try await applied([0], in: store)
    _ = try await World.premiseCard(in: store)
    let page = try await history(in: store)
    #expect(page.total == 2 && page.changes.map(\.state.proposal) == [second.id, first.id])
    let older = try #require(page.changes.last)
    #expect(older.entries.map(\.state) == [.applied, .applied, .declined, .pending])
    #expect(older.record?.card == first.card && older.session == .live(ProposalFixture.session) && older.refs == ["premise", "volume:vol_1", "fact:heir"])
    #expect(older.isRevertible && !older.isReverted)
  }

  @Test func shouldPageByOffsetAndLimit() async throws {
    let store = try await World.store()
    var proposals = [ProposalRecord]()
    for _ in 0..<4 { proposals.append(try await applied([0], in: store)) }
    let newest = Array(proposals.reversed().map(\.id))
    #expect(try await history(offset: 0, limit: 3, in: store).changes.map(\.state.proposal) == Array(newest.prefix(3)))
    let rest = try await history(offset: 3, limit: 3, in: store)
    #expect(rest.changes.map(\.state.proposal) == [newest[3]] && rest.total == 4)
  }

  @Test func shouldReadAProposalWhoseContentChangesWereAllUndoneAsReverted() async throws {
    let store = try await World.store()
    let proposal = try await applied([0, 3], in: store)
    _ = try await Projection.write(store) { transaction in
      try ProposalChangeRecord.recordUndo(
        try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 0), undoneState: ProposalFixture.postState("p0"), in: &transaction)
    }
    let change = try #require(try await history(in: store).changes.first)
    #expect(change.entries.map(\.state) == [.reverted, .declined, .declined, .pending])
    #expect(change.isReverted && !change.isRevertible)
  }

  @Test func shouldShowAChangeThisDeviceCannotReadAsUnreadable() async throws {
    let store = try await World.store()
    let proposal = try await applied([0, 1], in: store)
    let ref = try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 1)
    _ = try await Projection.write(store) { transaction in try transaction.set(ref, ["status": .int(9)]) }
    let change = try #require(try await history(in: store).changes.first)
    #expect(change.entries.map(\.state)[1] == .unreadable && !change.isReverted)
  }

  @Test func shouldListAnAppliedProposalThisDeviceCannotRead() async throws {
    let store = try await World.store()
    let id = UUID()
    _ = try await Projection.write(store) { transaction in try transaction.set(NovelForgeKey.proposal(id), ["card": ["novel": World.novel.json], "decision": "applied"]) }
    let change = try #require(try await history(in: store).changes.first)
    #expect(change.state.proposal == id && change.record == nil && change.entries.isEmpty && change.refs.isEmpty)
  }

  @Test func shouldKeepTheChangesOfADeletedChatDetached() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    _ = try await applied([0], session: session.id, in: store)
    try await store.deleteChatSession(session.id, novel: World.novel)
    let change = try #require(try await history(in: store).changes.first)
    #expect(change.session == .deleted(session.id) && change.state.session == session.id)
  }

  @Test func shouldReadACarriedRewriteAsItsLeaderStandsAndAFullyRevertedCardAsReverted() async throws {
    let store = try await World.store()
    let proposal = try await rewrites(in: store)
    var change = try #require(try await history(in: store).changes.first)
    #expect(change.entries.map(\.carriedBy) == [nil, 0, nil] && change.entries.map(\.state) == [.applied, .applied, .applied])
    #expect(change.entries.map(\.hasUndo) == [true, true, true] && change.isRevertible && !change.isReverted)
    _ = try await Projection.write(store) { transaction in
      try ProposalChangeRecord.recordUndo(
        try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 0), undoneState: ProposalFixture.postState("p0"), in: &transaction)
      try ProposalChangeRecord.recordUndo(
        try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 2), undoneState: ProposalFixture.postState("p0"), in: &transaction)
    }
    change = try #require(try await history(in: store).changes.first)
    #expect(change.entries.map(\.state) == [.reverted, .reverted, .reverted] && change.entries.map { $0.row.state } == [.reverted, .applied, .reverted])
    #expect(change.isReverted && !change.isRevertible)
  }

  @Test func shouldShowACarriedRewriteThisDeviceCannotReadAsUnreadableNotAsItsLeader() async throws {
    let store = try await World.store()
    let proposal = try await rewrites(in: store)
    let carried = try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 1)
    _ = try await Projection.write(store) { transaction in
      _ = try transaction.set(carried, ["status": .int(9)])
      for index in [0, 2] {
        try ProposalChangeRecord.recordUndo(
          try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: index), undoneState: ProposalFixture.postState("p0"), in: &transaction)
      }
    }
    let change = try #require(try await history(in: store).changes.first)
    #expect(change.entries.map(\.carriedBy) == [nil, nil, nil] && change.entries.map(\.state) == [.reverted, .unreadable, .reverted] && !change.isReverted)
  }

  @Test func shouldReadAFullyRevertedCardWithACarriedRewriteAsReverted() async throws {
    let store = try await World.store()
    let ops = try csOps(
      #"[{"op":"draft.rewrite_passage","chapter":1,"passage":"He was afraid of her, and he knew it.","replacement":"His grip went damp."},{"op":"draft.rewrite_passage","chapter":1,"passage":"worked his right wrist in slow circles.","replacement":"flexed his wrist."}]"#
    )
    let base = try ProposalFixture.card()
    let proposal = ProposalRecord(
      id: UUID(),
      card: try ProposalCard(novel: base.novel, session: base.session, message: base.message, kind: base.kind, summary: base.summary, changeSet: ops, baseline: base.baseline))
    try await ChatWorld.stage(proposal, in: store)
    let leader = try ProposalFixture.change(of: proposal, 0, undo: try ProposalFixture.undo("p-0"))
    let carried = try ProposalFixture.change(of: proposal, 1)
    _ = try await Projection.write(store) { transaction in
      try ProposalRecord.recordApply(proposal.ref, changes: [leader, carried], postState: ProposalFixture.postState("p1"), automatic: false, in: &transaction)
    }
    _ = try await Projection.write(store) { transaction in try ProposalChangeRecord.recordUndo(leader.ref, undoneState: ProposalFixture.postState("p0"), in: &transaction) }
    let change = try #require(try await store.load(ChatChangeHistory.self, ChatChangeHistoryQuery(novel: ChatOperationsWorld.novel)).page.value?.changes.first)
    #expect(change.isReverted, "entries: \(change.entries.map(\.state)) revertible: \(change.isRevertible)")
  }

  @Test func shouldLeaveTheStatesOfAProposalThisDeviceCannotReadAsRecorded() async throws {
    let store = try await World.store()
    let proposal = try rewriteCard()
    _ = try await Projection.write(store) { transaction in
      _ = try transaction.set(proposal.ref, ["card": proposal.card.json, "decision": "applied", "applied": .string("applied")])
      for change in try rewriteChanges(of: proposal) { _ = try change.create(in: &transaction) }
    }
    let change = try #require(try await history(in: store).changes.first)
    #expect(change.record == nil && change.entries.map(\.carriedBy) == [nil, nil, nil] && change.entries.map(\.hasUndo) == [true, false, true])
    #expect(change.entries.map(\.state) == [.applied, .applied, .applied])
  }

  @Test func shouldNotReadACardWhoseSelectedChangeHasNotArrivedAsReverted() async throws {
    let store = try await World.store()
    let proposal = try ProposalFixture.proposal()
    try await ChatWorld.stage(proposal, in: store)
    _ = try await Projection.write(store) { transaction in
      _ = try transaction.set(proposal.ref, ["decision": "applied", "applied": ProposalFixture.application(selected: [0, 1], "p1").json])
      _ = try ProposalFixture.change(of: proposal, 0, status: .reverted, undo: try ProposalFixture.undo("p-0")).create(in: &transaction)
    }
    let change = try #require(try await history(in: store).changes.first)
    #expect(change.entries.map(\.state) == [.reverted, .awaiting, .declined, .declined] && !change.isReverted)
  }

  @Test func shouldNotOfferToRevertAnAppliedChangeThatHoldsNoUndo() async throws {
    let store = try await World.store()
    let proposal = try ProposalFixture.proposal()
    try await ChatWorld.stage(proposal, in: store)
    let change = try ProposalFixture.change(of: proposal, 0)
    _ = try await Projection.write(store) { transaction in
      try ProposalRecord.recordApply(proposal.ref, changes: [change], postState: ProposalFixture.postState("p1"), automatic: false, in: &transaction)
    }
    let read = try #require(try await history(in: store).changes.first)
    #expect(read.entries.first?.state == .applied && read.entries.first?.hasUndo == false && !read.isRevertible)
  }

  @Test func shouldMarkOnlyTheSessionUnknownWhenTheChatsCannotBeRead() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    _ = try await applied([0], session: session.id, in: store)
    _ = try await applied([0], in: store)
    try await World.fault(ChatSessionState.databaseTableName, ProjectionFaults.key(NovelForgeKey.chatSession(session.id)), in: store)
    var sessions = try await history(in: store).changes.map(\.session)
    #expect(sessions == [.live(ProposalFixture.session), .unknown(session.id)])
    try await World.fault(ChatSessionState.databaseTableName, in: store)
    sessions = try await history(in: store).changes.map(\.session)
    #expect(sessions == [.unknown(ProposalFixture.session), .unknown(session.id)])
  }

  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldHoldTheAppliedProposalsOfTheRawStatesOnEveryReplica(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(
      derivations: ChatDerivations.all, operations: ProjectionOperations.novels + ProjectionOperations.chat, iterations: 6, steps: 40,
      settled: { _, store, _ in
        let rows = try await Projection.fetch(ProposalHistoryRow.all(), in: store).sorted { $0.proposal.uuidString < $1.proposal.uuidString }
        #expect(rows == (try await expectedHistory(in: store)))
      })
    try await property.check(order: order, seed: order == .causal ? 0xF23B5 : 0xF23B6)
  }
}
