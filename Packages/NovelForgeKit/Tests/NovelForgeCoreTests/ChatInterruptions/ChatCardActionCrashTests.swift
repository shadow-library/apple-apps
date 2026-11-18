import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
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

/// What an apply of the card's two actions left, without ids: each change's outcome and result, whether each approval of chapter 3 binds its head, and
/// whether it is final.
struct ActionFootprint: Equatable {
  let outcomes: [StoredEnum<ProposalChangeStatus>]
  let results: [ProposalChangeResult?]
  let approvals: [Bool]
  let final: Bool

  static func of(_ card: UUID, in book: ChapterBook) async throws -> ActionFootprint {
    let changes = [try await book.change(card, 0), try await book.change(card, 1)]
    let head = try await book.head(3)
    return ActionFootprint(
      outcomes: changes.map(\.actionOutcome), results: changes.map(\.result), approvals: try await book.approvals(3).map { $0.draftRevision == head },
      final: try await book.final(3) != nil)
  }
}

/// A process ended after the card's content committed and `settled` of its actions settled, the approval failing when the author holds unsaved edits.
struct ActionCrash: Sendable, CustomTestStringConvertible {
  let name: String
  let unsaved: Bool
  let settled: Int

  var testDescription: String { name }

  static let cases = [
    ActionCrash(name: "after the content, before any action", unsaved: false, settled: 0),
    ActionCrash(name: "between the approval and the finalize", unsaved: false, settled: 1),
    ActionCrash(name: "after the content, before an approval that fails", unsaved: true, settled: 0),
    ActionCrash(name: "between a failed approval and the finalize it skips", unsaved: true, settled: 1),
  ]

  func prepare(_ book: ChapterBook) async throws {
    guard unsaved else { return }
    _ = try await book.save(3, "Mine.\n\n\(StagingText.body)", summary: "It turns.", base: try await book.head(3))
  }

  /// The first `settled` actions, each in its own transaction as `applyProposal` runs them.
  func settle(_ card: UUID, in book: ChapterBook) async throws {
    let novel = book.novel
    var failed = false
    for index in 0..<settled {
      if failed {
        _ = try await book.run { try ProposalApply.failAction(proposal: card, index: index, novel: novel, failure: .previousActionFailed, in: &$0) }
        continue
      }
      do throws(StoreError) {
        _ = try await book.store.write { try ProposalApply.runAction(proposal: card, index: index, novel: novel, in: &$0) }
      } catch {
        guard case .aborted(let cause) = error, case .action(_, let refusal)? = cause as? ProposalApplyError else { throw error }
        _ = try await book.run { try ProposalApply.failAction(proposal: card, index: index, novel: novel, failure: ProposalChangeFailure(refusal), in: &$0) }
        failed = true
      }
    }
  }

  /// The same card applied on a vault of its own with nothing stopping it.
  func uninterrupted() async throws -> ActionFootprint {
    let vault = try await CrashVault.make(workspace: true)
    defer { vault.remove() }
    let book = try vault.open()
    let card = try await cardedActions(book)
    try await prepare(book)
    _ = try await book.store.applyProposal(card, selection: .indexes([0, 1]), context: book.context())
    return try await ActionFootprint.of(card, in: book)
  }
}

private let brokenWorkingCopies = "DROP TABLE IF EXISTS nf_local_draft_working_copy; CREATE TABLE nf_local_draft_working_copy (novel BLOB, chapter INTEGER)"

/// The pending-action rows each router request found.
private final class RowCounts: Sendable {
  private let state = Mutex<[Int]>([])

  var counts: [Int] { state.withLock { $0 } }

  func record(_ count: Int) {
    state.withLock { $0.append(count) }
  }
}

private func pendingActions(in store: VaultStore) async throws -> [PendingActionRow] {
  try await store.read { transaction in try PendingActions.rows(in: transaction.database) }
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
    #expect(try await Crash.interruptedApplies(in: launched.store) == [card])
    #expect(try await Crash.engine(launched.store, provider: idle).resumeInterruptedTurns().isEmpty)
    let summaries: [JSONValue?] = [["summary": "approved chapter 3's draft"], ["summary": "finalized chapter 3"]]
    #expect(try await [launched.change(card, 0), launched.change(card, 1)].map(\.result?.result) == summaries)
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

  // RULE E07: the launch sweep, run by resumeInterruptedTurns before any turn, finishes the actions the apply left as an uninterrupted apply would have
  @Test(arguments: ActionCrash.cases)
  func shouldRunTheRemainingActionsOnceAtLaunchAsAnUninterruptedApplyWould(_ crash: ActionCrash) async throws {
    let expected = try await crash.uninterrupted()
    let vault = try await CrashVault.make(workspace: true)
    defer { vault.remove() }
    let book = try vault.open()
    let card = try await cardedActions(book)
    try await crash.prepare(book)
    try await appliedContentOnly(card, in: book)
    try await crash.settle(card, in: book)
    #expect(try await pendingActions(in: book.store).map(\.actions) == [Array(crash.settled..<2)])

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    #expect(try await Crash.engine(launched.store, provider: idle).resumeInterruptedTurns().isEmpty)
    #expect(try await pendingActions(in: launched.store).isEmpty)
    #expect(try await ActionFootprint.of(card, in: launched) == expected)
    #expect(try await Crash.interruptedApplies(in: launched.store).isEmpty)

    let relaunched = try vault.open()
    #expect(try await Crash.engine(relaunched.store, provider: idle).resumeInterruptedActions().isEmpty)
    #expect(try await ActionFootprint.of(card, in: relaunched) == expected)
    #expect(idle.requests.isEmpty)
  }

  @Test func shouldForgetARowOfACardNotFoundAndSkipAndKeepAFaultedOne() async throws {
    let vault = try await CrashVault.make(workspace: true)
    defer { vault.remove() }
    let book = try vault.open()
    let card = try await cardedActions(book)
    try await appliedContentOnly(card, in: book)
    let (stray, novel) = (UUID(), book.novel)
    try await book.run { try PendingActions.record(proposal: stray, novel: novel, actions: [0], at: Date(timeIntervalSince1970: 0), in: $0.database) }
    try await book.tamper(brokenWorkingCopies)

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    #expect(try await Crash.engine(launched.store, provider: idle).resumeInterruptedTurns().isEmpty)
    let faulted = try #require(try await pendingActions(in: launched.store).first)
    let fault = try #require(faulted.fault)
    #expect(faulted == PendingActionRow(proposal: card, novel: novel, actions: [0, 1], attempts: 1, fault: fault))
    #expect(try await [launched.change(card, 0), launched.change(card, 1)].map(\.actionOutcome) == [.known(.pending), .known(.pending)])

    for attempt in 2...PendingActions.attemptLimit {
      let relaunched = try vault.open()
      #expect(try await Crash.engine(relaunched.store, provider: idle).resumeInterruptedActions() == [.faulted(proposal: card, code: fault)])
      #expect(try await pendingActions(in: relaunched.store).map(\.attempts) == [attempt])
    }
    let exhausted = try vault.open()
    try await exhausted.tamper("DROP TABLE nf_local_draft_working_copy")
    #expect(try await Crash.engine(exhausted.store, provider: idle).resumeInterruptedActions() == [.skipped(proposal: card, fault: fault)])
    #expect(try await pendingActions(in: exhausted.store).map(\.attempts) == [PendingActions.attemptLimit])
    #expect(try await exhausted.approvals(3).isEmpty)
  }

  // RULE E07: the sweep finishes before the first interrupted turn asks for its router
  @Test func shouldRunTheSweepBeforeAnyTurnResumes() async throws {
    let vault = try await CrashVault.make(workspace: true)
    defer { vault.remove() }
    let book = try vault.open()
    let card = try await cardedActions(book)
    try await appliedContentOnly(card, in: book)
    let provider = KillableProvider(turns: [.freeze([])])
    let engine = try await Crash.engine(book.store, provider: provider)
    _ = try await engine.send("What next?", session: World.session, novel: book.novel)
    try await provider.waitFrozen()

    let launched = try vault.open()
    let store = launched.store
    let seen = RowCounts()
    let answering = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Noted.")))])
    let relaunched = try await Crash.engine(store, provider: answering) { seen.record((try? await pendingActions(in: store).count) ?? -1) }
    let resumed = try await relaunched.resumeInterruptedTurns()
    #expect(resumed.count == 1)
    _ = try World.reply(of: await resumed[0].outcome())
    #expect(!seen.counts.isEmpty && seen.counts.allSatisfy { $0 == 0 })
    #expect(try await [launched.change(card, 0), launched.change(card, 1)].map(\.actionOutcome) == [.known(.applied), .known(.applied)])
  }
}
