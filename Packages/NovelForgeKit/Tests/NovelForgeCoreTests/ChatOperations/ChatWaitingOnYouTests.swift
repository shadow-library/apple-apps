import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatOperationsWorld

private func waiting(in store: VaultStore) async throws -> ChatWaitingContents {
  try #require(try await store.load(ChatWaitingOnYou.self, World.novel).contents.value)
}

@Suite("Waiting on you", TestTimeLimit.standard)
struct ChatWaitingOnYouTests {
  @Test func shouldListAPendingCardThatStillAppliesAsStaged() async throws {
    let store = try await World.store()
    let card = try await World.premiseCard(in: store)
    let contents = try await waiting(in: store)
    #expect(contents.cards.map(\.state.proposal) == [card.id] && contents.conflicted.isEmpty && contents.pendingCount == 1)
    #expect(contents.cards.first?.card == card.card && contents.cards.first?.conflict == nil && contents.cards.first?.session == .live(ChatWorld.session))
  }

  @Test func shouldMoveACardWhoseBaselineChangedToConflictedAndOutOfTheCount() async throws {
    let store = try await World.store()
    let stale = try await World.premiseCard(in: store)
    try await World.editBrief("A new brief", in: store)
    let fresh = try await World.premiseCard(in: store)
    let contents = try await waiting(in: store)
    #expect(contents.cards.map(\.state.proposal) == [fresh.id] && contents.pendingCount == 1)
    #expect(contents.conflicted.map(\.state.proposal) == [stale.id])
    #expect(contents.conflicted.first?.conflict == ChatCardConflict(refs: ["premise"], indexes: [0]))
    #expect(try await store.load(ChatPendingProposals.self, World.novel).count == .available(2))
  }

  @Test func shouldAgreeWithWhatAnApplyWouldDo() async throws {
    let store = try await World.store()
    let stale = try await World.premiseCard(in: store)
    try await World.editBrief("A new brief", in: store)
    let outcome = try await store.applyProposal(stale.id, selection: .whole, context: ProposalApplyContext(novel: World.novel, now: Date(), ageGate: AgeGate(passed: true)))
    guard case .conflicted = outcome else {
      Issue.record("the apply did not conflict")
      return
    }
    #expect(try await waiting(in: store).conflicted.map(\.state.proposal) == [stale.id])
  }

  @Test func shouldKeepACardThisDeviceCannotReadWaitingAndShown() async throws {
    let store = try await World.store()
    let id = UUID()
    _ = try await Projection.write(store) { transaction in try transaction.set(NovelForgeKey.proposal(id), ["card": ["novel": World.novel.json], "decision": "pending"]) }
    let contents = try await waiting(in: store)
    #expect(contents.cards.map(\.state.proposal) == [id] && contents.cards.first?.card == nil && contents.pendingCount == 1)
    #expect(contents.cards.first?.state.readability == .cardUnreadable)
  }

  @Test func shouldLeaveOutDecidedCardsAndOtherNovels() async throws {
    let store = try await World.store()
    let discarded = try await World.premiseCard(in: store)
    try await store.discardProposal(discarded.id, novel: World.novel)
    let other = try ProposalFixture.proposal(card: try ProposalFixture.card(novel: World.otherNovel))
    try await ChatWorld.stage(other, in: store)
    #expect(try await waiting(in: store) == ChatWaitingContents(cards: [], conflicted: [], actions: []))
  }

  @Test func shouldDetachTheCardsOfADeletedChat() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    _ = try await World.premiseCard(session: session.id, in: store)
    try await store.deleteChatSession(session.id, novel: World.novel)
    let contents = try await waiting(in: store)
    #expect(contents.cards.count == 1 && contents.cards.first?.session == .deleted(session.id) && contents.cards.first?.state.session == session.id)
  }

  @Test func shouldListAppliedActionsStillPendingUntilTheySettle() async throws {
    let store = try await World.store()
    let proposal = try ProposalFixture.proposal()
    try await ChatWorld.stage(proposal, in: store)
    try await ChatWorld.apply(proposal, selected: [0, 3], in: store)
    var contents = try await waiting(in: store)
    #expect(contents.actions == [ChatPendingAction(proposal: proposal.id, session: .live(ProposalFixture.session), indexes: [3])] && contents.pendingCount == 0)
    _ = try await Projection.write(store) { transaction in
      try ProposalChangeRecord.settleAction(
        try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: 3), result: ProposalChangeResult(result: ["summary": "done"]), in: &transaction)
    }
    contents = try await waiting(in: store)
    #expect(contents.actions.isEmpty)
  }

  @Test func shouldBeUnavailableWhileTheProposalsCannotBeRead() async throws {
    let store = try await World.store()
    _ = try await World.premiseCard(in: store)
    try await World.fault(ProposalState.databaseTableName, in: store)
    #expect(try await store.load(ChatWaitingOnYou.self, World.novel).contents.isUnavailable)
  }

  @Test func shouldKeepTheCardsWaitingAndMarkTheirSessionUnknownWhenTheChatsCannotBeRead() async throws {
    let store = try await World.store()
    let card = try await World.premiseCard(in: store)
    try await World.fault(ChatSessionState.databaseTableName, in: store)
    let contents = try await waiting(in: store)
    #expect(contents.cards.map(\.state.proposal) == [card.id] && contents.cards.first?.session == .unknown(ChatWorld.session))
    #expect(contents.cards.first?.session.id == ChatWorld.session)
  }
}
