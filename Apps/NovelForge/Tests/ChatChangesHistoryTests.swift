import Foundation
import NovelForgeCore
import ShadowCore
import Testing

@testable import NovelForge

private typealias Script = ChatCardsScript

/// An auto chat whose replies each apply one character the author named, so every reply leaves one applied change.
@MainActor
private struct HistoryWorld {
  let world: ChatCardsWorld
  /// Oldest first.
  let applied: [UUID]

  static let names = ["Mara", "Cole", "Ines"]

  static func make(_ count: Int) async throws -> HistoryWorld {
    let names = Array(names.prefix(count))
    let world = try await ChatCardsWorld.make(names.map { Script.reply("Noted.", ops: [Script.quotedCharacter($0.lowercased(), $0)]) }, mode: .auto)
    var applied = [UUID]()
    for name in names {
      let reply = try await world.reply(to: "\(name) is a smuggler who works the Saltgate docks.")
      applied.append(try #require(reply.appliedProposal))
    }
    return HistoryWorld(world: world, applied: applied)
  }

  func model(writer: (any ChatProposalWriting)? = nil, pageSize: Int = 30) -> ChatChangesModel {
    ChatChangesModel(context: world.context, writer: writer ?? world.writer, pageSize: pageSize)
  }
}

@MainActor
@Suite("Chat change history", .timeLimit(.minutes(3)))
struct ChatChangesHistoryTests {
  @Test func shouldPageTheHistoryNewestFirst() async throws {
    let history = try await HistoryWorld.make(3)
    let model = history.model(pageSize: 2)
    var task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the first page loads") { model.changes.count == 2 }
    #expect(model.changes.map(\.state.proposal) == Array(history.applied.reversed().prefix(2)))
    #expect(model.page?.total == 3 && model.hasMore)

    model.showMore()
    task.cancel()
    task = observing { await model.observe() }

    try await ChatWait.until("the next page joins it") { model.changes.count == 3 }
    #expect(model.changes.map(\.state.proposal) == Array(history.applied.reversed()))
    #expect(!model.hasMore)
    #expect(model.changes.allSatisfy { $0.isRevertible && !$0.isReverted })
    #expect(model.changes.map(ChatChangeLines.summary(of:)).allSatisfy { !$0.isEmpty })
  }

  @Test func shouldRevertATurnAndRollBackToHereThroughTheRevertFlow() async throws {
    let history = try await HistoryWorld.make(3)
    let model = history.model()
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the history loads") { model.changes.count == 3 }
    let newest = try #require(model.changes.first)

    model.revert(newest)
    #expect(model.revert.target == .proposals([history.applied[2]]))
    try await ChatWait.until("the impact loads") { model.revert.canConfirm }
    await model.revert.confirm()

    #expect(model.report == .reverted)
    try await ChatWait.until("the change reads undone") { model.changes.first?.isReverted == true }
    let undone = try #require(model.changes.first)
    #expect(!model.canRevert(undone) && !model.canRollBack(to: undone))
    #expect(ChatChangeLines.lines(of: undone).map(\.state) == [.reverted])

    let oldest = try #require(model.changes.last)
    model.rollBack(to: oldest)
    #expect(model.revert.target == .rollback(after: history.applied[0]) && model.report == nil)
    await model.revert.confirm()

    guard case .rolledBack(let result)? = model.report else {
      Issue.record("no rollback report")
      return
    }
    #expect(result.reverted.contains(history.applied[1]) && !result.reverted.contains(history.applied[0]) && result.refusal == nil)
    #expect(ChatChangesText.report(.rolledBack(ChatRollbackResult(reverted: [history.applied[1]], skipped: []))) == "Rolled back 1 change.")
    #expect(ChatChangesText.report(.rolledBack(ChatRollbackResult(reverted: history.applied, skipped: [UUID()]))) == "Rolled back 3 changes (1 with only actions skipped).")
    try await ChatWait.until("the rolled back change reads undone") { model.changes.dropLast().allSatisfy(\.isReverted) }
    #expect(model.changes.last?.isReverted == false)
  }

  @Test func shouldReportRolledBackNThenStoppedAndKeepItAfterTheSheetCloses() async throws {
    let history = try await HistoryWorld.make(1)
    let (first, stopped) = (UUID(), UUID())
    let writer = ScriptedProposalWriter(base: history.world.writer)
    writer.queueRollback(ChatRollbackResult(reverted: [first], skipped: [], stoppedAt: stopped, refusal: ChatCardRefusal(code: "RFN_006")))
    let model = history.model(writer: writer)
    let task = observing { await model.observe() }
    defer { task.cancel() }
    try await ChatWait.until("the history loads") { model.changes.count == 1 }

    model.rollBack(to: try #require(model.changes.first))
    await model.revert.confirm()

    #expect(model.revert.isPresented && model.revert.notice?.error.detail == "RFN_006")
    let report = try #require(model.report)
    #expect(report.isStopped)
    #expect(ChatChangesText.report(report).hasPrefix("Rolled back 1 change, then stopped: "))
    model.revert.cancel()
    #expect(!model.revert.isPresented && model.report == report)
    model.dismissReport()
    #expect(model.report == nil)
  }

  @Test func shouldListCarriedRewritesActionsAndUndoneChangesButNotDeclinedOnes() {
    let rewrite = { (index: Int, label: String) in
      ChatOp(
        index: index, stored: .object(["op": .string("draft.rewrite_passage"), "chapter": .int(2), "label": .string(label)]), problems: [])
    }
    let action = ChatOp(index: 2, stored: .object(["op": .string("action.approve_draft"), "chapter": .int(2)]), problems: [])
    let ops = [rewrite(0, "Opening"), rewrite(1, "Harbour"), action, rewrite(3, "Left out"), rewrite(4, "Ending")]
    let entries: [ChatChangeLines.Entry] = [
      .init(index: 0, state: .applied, isAction: false, carriers: []),
      .init(index: 1, state: .reverted, isAction: false, carriers: [0]),
      .init(index: 2, state: .pending, isAction: true, carriers: []),
      .init(index: 3, state: .declined, isAction: false, carriers: []),
      .init(index: 4, state: .uncertain, isAction: false, carriers: [0, 1]),
    ]

    let lines = ChatChangeLines.lines(entries, ops: ops)

    #expect(lines.map(\.index) == [0, 1, 2, 4])
    #expect(lines.map(\.state) == [.applied, .reverted, .pending, .uncertain])
    #expect(lines.map(\.isAction) == [false, false, true, false])
    #expect(lines.map(ChatChangesText.carried) == [nil, "Moves with “\(ops[0].subject)”.", nil, "Moves with one of “\(ops[0].subject)”, “\(ops[1].subject)”."])
    #expect(lines[2].subject == action.subject)
    #expect(ChatChangesText.count(lines) == "4 changes, 1 undone")
    #expect(ChatChangeLines.lines([.init(index: 7, state: .unreadable, isAction: false, carriers: [])], ops: []).map(\.subject) == ["Change 8"])
  }
}
