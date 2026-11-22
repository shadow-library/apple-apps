import Foundation
import NovelForgeCore
import ShadowAppShell
import Testing

@testable import NovelForge

private typealias Script = ChatCardsScript

@MainActor
@Suite("Chat card flows", TestTimeLimit.standard)
struct ChatCardsFlowTests {
  private static let threePlaces = Script.reply(
    "Three places.", ops: [Script.idea("hall", "Saltgate Hall"), Script.idea("quay", "Ember Quay"), Script.idea("dock", "Low Dock")])

  private func ideaReceipt(_ world: ChatCardsWorld, writer: ScriptedProposalWriter) async throws -> (ChatReceiptModel, Task<Void, Never>) {
    let reply = try await world.reply(to: "Add three places.")
    let model = try world.receipt(reply, writer: writer)
    let task = observing { await model.observe() }
    try await ChatWait.until("the receipt loads") { model.changes.count == 3 }
    return (model, task)
  }

  private func undoIdea(_ model: ChatReceiptModel, _ index: Int, scope: LedgerRejectionScope = .notNow) async throws {
    await model.toggle(model.changes[index])
    try await ChatWait.until("the impact loads") { model.revert.impact != .loading }
    model.revert.ideaScope = scope
    await model.revert.confirm()
  }

  @Test func shouldSendTheChosenScopeWithTheUndoneIdeaAlone() async throws {
    let world = try await ChatCardsWorld.make([Self.threePlaces], mode: .auto)
    let writer = ScriptedProposalWriter(base: world.writer)
    let (model, task) = try await ideaReceipt(world, writer: writer)
    defer { task.cancel() }

    try await undoIdea(model, 0, scope: .never)

    #expect(writer.undos == [ScriptedProposalWriter.Undo(index: 0, idea: .never)])
    try await ChatWait.until("the idea reads undone") { model.state(of: model.changes[0]) == .reverted }
    #expect(!model.revert.isPresented)
  }

  @Test func shouldChainTheChangesARefusalNamesAndSayWhereItStopped() async throws {
    let world = try await ChatCardsWorld.make([Self.threePlaces], mode: .auto)
    let writer = ScriptedProposalWriter(base: world.writer)
    writer.refuseUndo(of: 0, ChatCardRefusal(code: "RFN_015", indexes: [1]))
    writer.refuseUndo(of: 1, ChatCardRefusal(code: "RFN_015", indexes: [2]))
    writer.refuseUndo(of: 1, ChatCardRefusal(code: "RFN_018", indexes: [1]))
    let (model, task) = try await ideaReceipt(world, writer: writer)
    defer { task.cancel() }

    try await undoIdea(model, 0, scope: .never)
    #expect(model.prompt == ChatChangePrompt(index: 0, direction: .undo, kind: .dependencies, before: [1], moved: []))

    await model.confirmPrompt()
    #expect(model.prompt == ChatChangePrompt(index: 0, direction: .undo, kind: .dependencies, before: [2, 1], moved: []))

    await model.confirmPrompt()
    #expect(writer.undos.map(\.index) == [0, 1, 2, 1])
    #expect(writer.undos.map(\.idea) == [.never, nil, nil, nil])
    #expect(model.notices[1]?.error.detail == "RFN_018")
    let stopped = ChatChangeCopy.stopped(.undo, at: model.subject(of: 1), moved: [model.subject(of: 2)])
    #expect(model.notices[0]?.error.headline == stopped)
    #expect(stopped.hasSuffix(" " + String(localized: "“\(model.subject(of: 2))” was already undone.", table: "ChatCards")))
    try await ChatWait.until("the first step reads undone") { model.state(of: model.changes[2]) == .reverted }
  }

  @Test func shouldClearAConflictSeenOnApplyOnceTheCardIsDecided() async throws {
    let world = try await ChatCardsWorld.make([Script.reply("A place.", ops: [Script.idea("hall", "Saltgate Hall")])])
    let writer = ScriptedProposalWriter(base: world.writer)
    writer.queueApply(.conflicted(indexes: [0]))
    let reply = try await world.reply(to: "Add a place.")
    let model = world.card(try #require(reply.cardProposal), writer: writer)
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the card loads") { model.status == .pending }

    await model.apply()
    #expect(model.status == .conflicted && model.notice?.error.detail == "RFN_003")

    try await world.writer.discard(model.proposal, novel: world.novel)
    try await ChatWait.until("the decision shows") { model.status == .discarded }
    #expect(model.notice == nil)
  }

  @Test func shouldRevertAgainAcceptingChangedDeclinedChanges() async throws {
    let proposal = UUID()
    let writer = ScriptedProposalWriter()
    writer.refuseRevert(ChatCardRefusal(code: "refinement.declined_changed", indexes: [1]))
    let flow = ChatRevertFlow(novel: UUID(), writer: writer)
    var finished: ChatRevertFlow.Outcome?
    flow.onFinished = { finished = $0 }
    flow.open(.proposals([proposal]))
    try await ChatWait.until("the impact loads") { flow.impact != .loading }

    await flow.confirm()
    #expect(flow.changedDeclined?.proposal == proposal && flow.changedDeclined?.indexes == [1])
    #expect(flow.notice == nil && !flow.canConfirm && finished == nil)

    await flow.acceptChangedDeclined()
    #expect(writer.reverts == [.init(proposal: proposal, accepting: []), .init(proposal: proposal, accepting: [1])])
    #expect(finished == .reverted([proposal]))
  }

  @Test func shouldRevertTheApplyARollbackStoppedAtAloneThenRollBackAgain() async throws {
    let (anchor, first, stopped, last) = (UUID(), UUID(), UUID(), UUID())
    let writer = ScriptedProposalWriter()
    let declined = ChatCardRefusal(code: "refinement.declined_changed", indexes: [2])
    writer.queueRollback(ChatRollbackResult(reverted: [first], skipped: [], stoppedAt: stopped, refusal: declined))
    writer.queueRollback(ChatRollbackResult(reverted: [last], skipped: []))
    let flow = ChatRevertFlow(novel: UUID(), writer: writer)
    var finished: ChatRevertFlow.Outcome?
    flow.onFinished = { finished = $0 }
    flow.open(.rollback(after: anchor))
    #expect(flow.impact == .notShown)

    await flow.confirm()
    #expect(flow.changedDeclined?.proposal == stopped && flow.changedDeclined?.indexes == [2])
    #expect(flow.rolledBack?.reverted == [first])

    await flow.acceptChangedDeclined()
    #expect(writer.reverts == [.init(proposal: stopped, accepting: [2])])
    #expect(finished == .rolledBack(ChatRollbackResult(reverted: [first, stopped, last], skipped: [])))
  }

  @Test func shouldKeepWhatARollbackUndidBeforeAnotherStop() async throws {
    let (anchor, first, stopped) = (UUID(), UUID(), UUID())
    let writer = ScriptedProposalWriter()
    writer.queueRollback(ChatRollbackResult(reverted: [first], skipped: [], stoppedAt: stopped, refusal: ChatCardRefusal(code: "RFN_006")))
    let flow = ChatRevertFlow(novel: UUID(), writer: writer)
    flow.open(.rollback(after: anchor))

    await flow.confirm()

    #expect(flow.rolledBack == ChatRollbackResult(reverted: [first], skipped: [], stoppedAt: stopped, refusal: ChatCardRefusal(code: "RFN_006")))
    #expect(flow.notice?.error.detail == "RFN_006" && flow.changedDeclined == nil && flow.isPresented)
  }

  @Test func shouldMergeImpactsOncePerRecordAndCountKindsInTheOrderTheyAppear() {
    let draft = ChatUndoDependent(kind: "draft", ref: "draft:3", chapter: 3, isFinal: false)
    let plan = ChatUndoDependent(kind: "plan", ref: "chapter:4", chapter: 4, isFinal: false)
    let merged = ChatUndoImpact.merged([
      ChatUndoImpact(dependents: [draft], finalUnaffected: 1), ChatUndoImpact(dependents: [draft, plan], finalUnaffected: 2, unreadable: 1),
    ])

    #expect(merged == ChatUndoImpact(dependents: [draft, plan], finalUnaffected: 3, unreadable: 1))
    #expect(
      ChatUndoImpactText(merged).counts == [String(localized: "\(1) drafts", table: "ChatCards"), String(localized: "\(1) chapter plans", table: "ChatCards")])
  }
}
