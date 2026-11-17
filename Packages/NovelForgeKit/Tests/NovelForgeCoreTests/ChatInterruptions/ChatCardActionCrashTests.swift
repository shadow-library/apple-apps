import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld
private typealias Crash = CrashWorld

/// A turn on the workspace vault whose reply cards an approval of chapter 3 and its finalize; answers the card.
private func cardedActions(_ book: ChapterBook) async throws -> UUID {
  let changeSet = "[\(ApplyWorld.approve3),\(ApplyWorld.finalize3)]"
  let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Ready to approve and finalize it.")), ("changeSet", changeSet))])
  let engine = try await Crash.engine(book.store, provider: provider)
  let reply = try World.reply(of: await engine.send("Approve chapter 3 and finalize it.", session: World.session, novel: book.novel).outcome())
  let record = try #require(try await World.messages(in: book.store).last)
  #expect(record.id == reply && record.appliedProposal == nil)
  return try #require(record.cardProposal)
}

/// The author applies both actions of the card and the process ends once the content committed, before any action ran (proposal-apply.service.ts:220).
private func appliedContentOnly(_ card: UUID, in book: ChapterBook) async throws {
  let context = book.context()
  let outcome = try await book.run { try ProposalApply.apply(proposal: card, selection: .indexes([0, 1]), context: context, in: &$0) }
  #expect(outcome == .applied([ProposalChangeOutcome(index: 0, status: .pending, source: nil), ProposalChangeOutcome(index: 1, status: .pending, source: nil)]))
}

// RULE F16/F27: a card's actions run after its content, each in its own transaction, and a launch resumes the ones still pending, each once
@Suite("Card actions killed mid-apply", .serialized, .timeLimit(.minutes(3)))
struct ChatCardActionCrashTests {
  @Test func shouldRunBothActionsOnceWhenKilledAfterTheReplyAndTheCardsContent() async throws {
    let vault = try await CrashVault.make(workspace: true)
    defer { vault.remove() }
    let book = try vault.open()
    let card = try await cardedActions(book)
    let head = try #require(try await book.head(3))

    let afterReply = try vault.open()
    let idle = ScriptedModelProvider()
    let engine = try await Crash.engine(afterReply.store, provider: idle)
    #expect(try await engine.resumeInterruptedTurns().isEmpty)
    #expect(try await Crash.interruptedApplies(in: afterReply.store).isEmpty)
    try await appliedContentOnly(card, in: afterReply)

    let launched = try vault.open()
    #expect(try await Crash.engine(launched.store, provider: idle).resumeInterruptedTurns().isEmpty)
    #expect(try await Crash.interruptedApplies(in: launched.store) == [card])
    let results = try await launched.store.resumeProposalActions(card, novel: launched.novel)
    #expect(results.map(\.outcome) == [.known(.applied), .known(.applied)] && results.allSatisfy { $0.summary != nil })
    #expect(try await launched.approvals(3).map(\.draftRevision) == [head])
    #expect(try await launched.final(3) != nil)
    #expect(try await Crash.interruptedApplies(in: launched.store).isEmpty)

    let relaunched = try vault.open()
    let again = try await relaunched.store.resumeProposalActions(card, novel: relaunched.novel)
    #expect(again == [ProposalActionResult(index: 0, outcome: .known(.applied)), ProposalActionResult(index: 1, outcome: .known(.applied))])
    #expect(try await relaunched.approvals(3).count == 1)
    #expect(idle.requests.isEmpty)
  }

  @Test func shouldRunOnlyTheSecondActionWhenKilledBetweenApproveAndFinalize() async throws {
    let vault = try await CrashVault.make(workspace: true)
    defer { vault.remove() }
    let book = try vault.open()
    let card = try await cardedActions(book)
    let head = try #require(try await book.head(3))
    try await appliedContentOnly(card, in: book)
    let novel = book.novel
    let approved = try await book.run { try ProposalApply.runAction(proposal: card, index: 0, novel: novel, in: &$0) }
    #expect(approved == .ran(summary: "approved chapter 3's draft"))

    let launched = try vault.open()
    #expect(try await Crash.interruptedApplies(in: launched.store) == [card])
    let results = try await launched.store.resumeProposalActions(card, novel: novel)
    #expect(results == [ProposalActionResult(index: 0, outcome: .known(.applied)), ProposalActionResult(index: 1, outcome: .known(.applied), summary: "finalized chapter 3")])
    #expect(try await launched.approvals(3).map(\.draftRevision) == [head])
    #expect(try await launched.final(3) != nil)
    #expect(try await Crash.interruptedApplies(in: launched.store).isEmpty)
  }

  // No device owns a resume: two devices resuming one interrupted apply at once both run its actions, and the duplicates are harmless once they meet
  @Test func shouldConvergeWhenTwoDevicesResumeTheSameInterruptedApply() async throws {
    let reconciler = try ChatWorld.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: 0xF27))
    let here = ChapterBook(store: await replicas.store(0), clock: OperationClock())
    let there = ChapterBook(store: await replicas.store(1), clock: OperationClock())
    let novel = here.novel
    try await here.run { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      _ = try ChatSessionRecord(id: World.session, novel: novel).create(in: &transaction)
    }
    try await here.finalized(through: 2)
    try await here.draft(3, StagingText.body)
    let card = try await cardedActions(here)
    let head = try #require(try await here.head(3))
    try await appliedContentOnly(card, in: here)
    _ = try await replicas.write(0) { _ in }
    try await replicas.settle()
    #expect(try await Crash.interruptedApplies(in: there.store) == [card])

    async let resumedHere = here.store.resumeProposalActions(card, novel: novel)
    async let resumedThere = there.store.resumeProposalActions(card, novel: novel)
    let (one, two) = try await (resumedHere, resumedThere)
    #expect(one.map(\.outcome) == [.known(.applied), .known(.applied)] && two.map(\.outcome) == [.known(.applied), .known(.applied)])
    _ = try await replicas.write(0) { _ in }
    _ = try await replicas.write(1) { _ in }
    try await replicas.settle()

    for book in [here, there] {
      #expect(try await book.final(3) != nil)
      #expect(try await book.approvals(3).allSatisfy { $0.draftRevision == head })
      #expect(try await book.change(card, 0).actionOutcome == .known(.applied))
      #expect(try await book.change(card, 1).actionOutcome == .known(.applied))
      #expect(try await Crash.interruptedApplies(in: book.store).isEmpty)
      let approvals = try await book.approvals(3).count
      #expect(try await book.store.resumeProposalActions(card, novel: novel).map(\.summary) == [nil, nil])
      #expect(try await book.approvals(3).count == approvals)
    }
    #expect(try await here.approvals(3).count == there.approvals(3).count)
    #expect(try await Crash.footprint(in: here.store) == Crash.footprint(in: there.store))
  }
}
