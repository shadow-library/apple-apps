import Foundation
import NovelForgeCore
import Observation
import ShadowStore

enum ChatChangeDirection: Equatable {
  case undo
  case redo
}

/// A refusal naming other changes of the reply, put to the author before anything else moves (apps/novel-forge-web/src/features/chat/progress-panel-view.ts:587-592).
struct ChatChangePrompt: Equatable {
  enum Kind: Equatable {
    /// RFN_015 / RFN_016: `before` moves first, the chosen change last.
    case dependencies
    /// declinedChanged: changes left out of the card changed since; the author accepts them as never applied.
    case changedDeclined([Int])
  }

  let index: Int
  let direction: ChatChangeDirection
  let kind: Kind
  let before: [Int]
  let moved: [Int]

  var steps: [Int] { before + [index] }
}

/// TurnReceipt.tsx:83-98 with the panel's AppliedChanges (ProgressPanel.tsx:258-300): each applied change with undo and redo, and Undo all.
@MainActor
@Observable
final class ChatReceiptModel {
  let proposal: UUID
  let reply: ChatMessageRecord
  let context: NovelContext
  let revert: ChatRevertFlow
  private(set) var busy: Int?
  private(set) var notices: [Int: ChatCardNotice] = [:]
  private(set) var prompt: ChatChangePrompt?
  private(set) var generation = 0
  private let writer: any ChatProposalWriting
  private let observer = ReadObserver<ChatCardSnapshot>()
  @ObservationIgnored private var accepting: Set<Int> = []
  /// The scope the author chose for the idea being undone, sent with that change alone.
  @ObservationIgnored private var ideaScope: (index: Int, scope: LedgerRejectionScope)?

  init(proposal: UUID, reply: ChatMessageRecord, context: NovelContext, writer: any ChatProposalWriting) {
    self.proposal = proposal
    self.reply = reply
    self.context = context
    self.writer = writer
    revert = ChatRevertFlow(novel: context.novel, writer: writer)
    revert.undoChange = { [weak self] index, scope in await self?.undoIdea(index, scope: scope) }
  }

  var state: Loadable<ChatCardSnapshot> { observer.state }

  var snapshot: ChatCardSnapshot? { state.value }

  /// progress-panel-view.ts:272-296: the content changes, never the actions, which hold no undo.
  var changes: [ChatOp] { (snapshot?.ops ?? []).filter { !$0.isAction && snapshot?.state(of: $0.index) != nil } }

  var isLocked: Bool { busy != nil || revert.isRunning }

  func state(of op: ChatOp) -> ProposalChangeEntryState? { snapshot?.state(of: op.index) }

  /// A rewrite carried by another holds no undo of its own: it moves with its leader, which `carriedBy` names.
  func canToggle(_ op: ChatOp) -> Bool {
    guard let entry = snapshot?.entry(op.index), entry.row.hasUndo, entry.carriers.isEmpty else { return false }
    return entry.state == .applied || entry.state == .reverted
  }

  func isIdea(_ op: ChatOp) -> Bool { snapshot?.isIdea(op.index) == true }

  func leader(of op: ChatOp) -> Int? { snapshot?.entry(op.index)?.carriedBy }

  /// Why a change the reply selected could not be saved, as its row says it.
  func failure(of op: ChatOp) -> String? {
    guard state(of: op) == .failed else { return nil }
    let reason = snapshot?.failures[op.index].map(ChatCardsErrors.failure) ?? ChatCardsErrors.failure("")
    return String(localized: "Couldn't be saved: \(reason)", table: "ChatCards")
  }

  var canUndoAll: Bool { snapshot?.isRevertible == true && !isLocked }

  /// progress-panel-view.ts:415-445
  var title: String {
    let live = changes.filter { state(of: $0) == .applied }.count
    let undone = changes.filter { state(of: $0) == .reverted }.count
    if live > 0 { return String(localized: "Updated your story · \(live) changes", table: "ChatCards") }
    if undone > 0 { return String(localized: "Every change from this reply was undone.", table: "ChatCards") }
    return String(localized: "Nothing from this reply could be saved.", table: "ChatCards")
  }

  var detail: String? {
    let live = changes.filter { state(of: $0) == .applied }.count
    let undone = changes.filter { state(of: $0) == .reverted }.count
    guard live > 0, undone > 0 else { return nil }
    return String(localized: "\(undone) undone", table: "ChatCards")
  }

  func observe() async {
    let (store, proposal) = (context.store, proposal)
    await observer.run { store.observeReads { transaction in try ChatCardSnapshot.load(proposal, in: transaction) } }
  }

  func retryReading() {
    generation += 1
  }

  /// An idea asks first how long to turn it down; the undo itself then runs here, so the changes that rely on it are put to the author too.
  func toggle(_ op: ChatOp) async {
    guard canToggle(op), !isLocked else { return }
    let direction: ChatChangeDirection = state(of: op) == .applied ? .undo : .redo
    if direction == .undo && isIdea(op) {
      revert.open(.change(proposal: proposal, index: op.index, isIdea: true))
      return
    }
    await run(direction, steps: [op.index])
  }

  func confirmPrompt() async {
    guard let prompt, !isLocked else { return }
    if case .changedDeclined(let indexes) = prompt.kind { accepting.formUnion(indexes) }
    await run(prompt.direction, steps: prompt.steps)
  }

  func cancelPrompt() {
    prompt = nil
    ideaScope = nil
  }

  func undoAll() {
    guard canUndoAll else { return }
    revert.open(.proposals([proposal]))
  }

  /// RFN_006's recovery for a twin: redo the other reply's change, which brings back what both created.
  func recover(_ index: Int) async {
    guard case .redoTwin(let twin, let twinIndex)? = notices[index]?.recovery, !isLocked else { return }
    busy = index
    defer { busy = nil }
    do throws(ChatCardRefusal) {
      _ = try await writer.redo(twin, index: twinIndex, accepting: [], novel: context.novel)
      notices[index] = nil
    } catch {
      notices[index] = ChatCardNotice(error: ChatCardsErrors.presented(error, during: .redo))
    }
  }

  func subject(of index: Int) -> String {
    snapshot?.ops.first { $0.index == index }?.subject ?? String(localized: "Change \(index + 1)", table: "ChatCards")
  }

  private func undoIdea(_ index: Int, scope: LedgerRejectionScope) async {
    ideaScope = (index, scope)
    await run(.undo, steps: [index])
  }

  /// runOpSequence (progress-panel-view.ts:600-616): `steps` in order, the chosen change last.
  private func run(_ direction: ChatChangeDirection, steps: [Int]) async {
    guard let target = steps.last else { return }
    busy = target
    prompt = nil
    for step in steps { notices[step] = nil }
    defer { busy = nil }
    for (position, step) in steps.enumerated() {
      let moved = Array(steps[..<position])
      do throws(ChatCardRefusal) {
        _ = try await move(direction, step)
      } catch {
        await refused(error, direction: direction, steps: steps, at: position, moved: moved)
        return
      }
    }
    ideaScope = nil
  }

  private func move(_ direction: ChatChangeDirection, _ index: Int) async throws(ChatCardRefusal) -> Bool {
    switch direction {
    case .undo:
      let scope = ideaScope?.index == index ? ideaScope?.scope : nil
      return try await writer.undo(proposal, index: index, idea: scope, accepting: accepting, novel: context.novel)
    case .redo:
      return try await writer.redo(proposal, index: index, accepting: accepting, novel: context.novel)
    }
  }

  private func refused(_ refusal: ChatCardRefusal, direction: ChatChangeDirection, steps: [Int], at position: Int, moved: [Int]) async {
    guard let target = steps.last else { return }
    let step = steps[position]
    let blocking = direction == .undo ? "RFN_015" : "RFN_016"
    // progress-panel-view.ts:609-611
    let pending = Array(steps[position..<(steps.count - 1)])
    if refusal.code == blocking, !refusal.indexes.isEmpty {
      let before = Self.unique(refusal.indexes + pending).filter { $0 != target && !moved.contains($0) }
      prompt = ChatChangePrompt(index: target, direction: direction, kind: .dependencies, before: before, moved: moved)
      return
    }
    if refusal.code == "refinement.declined_changed" {
      prompt = ChatChangePrompt(index: target, direction: direction, kind: .changedDeclined(refusal.indexes), before: pending, moved: moved)
      return
    }
    ideaScope = nil
    if direction == .undo, refusal.code == "RFN_006", let twin = await twin(of: step) {
      notices[step] = ChatCardNotice(error: ChatCardsErrors.twinRemoved(refusal), recovery: .redoTwin(proposal: twin.proposal, index: twin.index))
    } else {
      notices[step] = ChatCardNotice(error: ChatCardsErrors.presented(refusal, during: direction == .undo ? .undo : .redo))
    }
    guard step != target else { return }
    let stopped = ChatChangeCopy.stopped(direction, at: subject(of: step), moved: moved.map(subject(of:)))
    notices[target] = ChatCardNotice(error: PresentedError(headline: stopped, detail: nil))
  }

  /// F26 finding A: an automatic apply (only those redo change by change, RFN_014) of another reply to the message, undone on the same record.
  private func twin(of index: Int) async -> (proposal: UUID, index: Int)? {
    guard let answers = reply.answers, let op = snapshot?.ops.first(where: { $0.index == index }) else { return nil }
    let (reply, identity) = (reply, op.identity)
    return try? await context.store.read { transaction -> (proposal: UUID, index: Int)? in
      let replies = try ChatMessageRecord.listing(session: reply.session, novel: reply.novel, in: transaction).records
      let others = replies.filter { $0.id != reply.id && $0.answers == answers && $0.role == .known(.assistant) }
      for other in others.flatMap({ [$0.appliedProposal, $0.cardProposal].compactMap(\.self) }) {
        let snapshot = try ChatCardSnapshot.load(other, in: transaction)
        guard snapshot.isAutomatic else { continue }
        if let match = snapshot.ops.first(where: { $0.identity == identity && snapshot.state(of: $0.index) == .reverted }) { return (other, match.index) }
      }
      return nil
    }
  }

  private static func unique(_ indexes: [Int]) -> [Int] {
    var seen = Set<Int>()
    return indexes.filter { seen.insert($0).inserted }
  }
}

/// progress-panel-view.ts:578-621
enum ChatChangeCopy {
  static func dependencies(_ direction: ChatChangeDirection, labels: [String], moved: [String]) -> String {
    let others = quoted(labels)
    let lead =
      switch direction {
      case .undo: String(localized: "Other changes rely on it. Undo these too: \(others).", table: "ChatCards")
      case .redo: String(localized: "It relies on changes that are undone. Redo these first: \(others).", table: "ChatCards")
      }
    return lead + alreadyMoved(direction, moved)
  }

  static func stopped(_ direction: ChatChangeDirection, at failed: String, moved: [String]) -> String {
    let lead =
      switch direction {
      case .undo: String(localized: "Stopped at “\(failed)”, so this wasn't undone.", table: "ChatCards")
      case .redo: String(localized: "Stopped at “\(failed)”, so this wasn't redone.", table: "ChatCards")
      }
    return lead + alreadyMoved(direction, moved)
  }

  static func alreadyMoved(_ direction: ChatChangeDirection, _ moved: [String]) -> String {
    guard !moved.isEmpty else { return "" }
    let names = quoted(moved)
    switch (direction, moved.count == 1) {
    case (.undo, true): return " " + String(localized: "\(names) was already undone.", table: "ChatCards")
    case (.undo, false): return " " + String(localized: "\(names) were already undone.", table: "ChatCards")
    case (.redo, true): return " " + String(localized: "\(names) was already redone.", table: "ChatCards")
    case (.redo, false): return " " + String(localized: "\(names) were already redone.", table: "ChatCards")
    }
  }

  private static func quoted(_ labels: [String]) -> String {
    labels.map { "“\($0)”" }.joined(separator: ", ")
  }
}
