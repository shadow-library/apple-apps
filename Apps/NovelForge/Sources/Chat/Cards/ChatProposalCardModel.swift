import Foundation
import NovelForgeCore
import Observation
import ShadowStore

/// TurnProposalCard.tsx:55-108: suggested changes reviewed one by one, re-read on every commit so a synced decision or a conflict shows at once.
@MainActor
@Observable
final class ChatProposalCardModel {
  let proposal: UUID
  let context: NovelContext
  let revert: ChatRevertFlow
  var expanded: Set<Int> = []
  private(set) var isBusy = false
  private(set) var notice: ChatCardNotice?
  private(set) var generation = 0
  /// Failure codes of the last apply here, shown until the change records arrive.
  private(set) var lastFailures: [Int: String] = [:]
  private var declined: Set<Int>?
  private var conflictedOnApply = false
  private let writer: any ChatProposalWriting
  private let observer = ReadObserver<ChatCardSnapshot>()

  init(proposal: UUID, context: NovelContext, writer: any ChatProposalWriting) {
    self.proposal = proposal
    self.context = context
    self.writer = writer
    revert = ChatRevertFlow(novel: context.novel, writer: writer)
  }

  var state: Loadable<ChatCardSnapshot> { observer.state }

  var snapshot: ChatCardSnapshot? { state.value }

  var ops: [ChatOp] { snapshot?.ops ?? [] }

  var status: ChatCardStatus {
    guard let snapshot else { return .absent }
    if snapshot.status == .pending && conflictedOnApply { return .conflicted }
    return snapshot.status
  }

  var isPending: Bool { status == .pending }

  func isSelectable(_ op: ChatOp) -> Bool { isPending && op.isReadable && !op.isJobAction }

  func isSelected(_ op: ChatOp) -> Bool { isSelectable(op) && !currentDeclined.contains(op.index) }

  var selected: [Int] { ops.filter(isSelected).map(\.index) }

  var declinedCount: Int { ops.count - selected.count }

  var canApply: Bool { isPending && !isBusy && !selected.isEmpty }

  var canDiscard: Bool { (status == .pending || status == .conflicted) && !isBusy }

  var canRevert: Bool { status == .applied && snapshot?.isRevertible == true && !isBusy && !revert.isRunning }

  func failureCode(of index: Int) -> String? { snapshot?.failures[index] ?? lastFailures[index] }

  func observe() async {
    let (store, proposal) = (context.store, proposal)
    await observer.run(
      { store.observeReads { transaction in try ChatCardSnapshot.load(proposal, in: transaction) } },
      onValue: { [weak self] snapshot in
        self?.changed(snapshot)
      })
  }

  func retryReading() {
    generation += 1
  }

  func toggle(_ op: ChatOp) {
    guard isSelectable(op) else { return }
    var next = currentDeclined
    if next.contains(op.index) { next.remove(op.index) } else { next.insert(op.index) }
    declined = next
  }

  func toggleExpanded(_ index: Int) {
    if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
  }

  /// A passage rewrite opens on its diff (TurnProposalCard.tsx:127).
  func isExpanded(_ op: ChatOp) -> Bool { op.isPassageRewrite != expanded.contains(op.index) }

  /// TurnProposalCard.tsx:87-107: the selected indexes, named explicitly, so a one-way door the author selected is reachable at all.
  func apply() async {
    guard canApply else { return }
    let indexes = selected
    await perform(.apply) { () async throws(ChatCardRefusal) in
      switch try await self.writer.apply(self.proposal, indexes: indexes, novel: self.context.novel) {
      case .conflicted:
        self.conflictedOnApply = true
        self.notice = ChatCardNotice(error: PresentedError(headline: ChatCardsErrors.conflicted, detail: "RFN_003"))
      case .applied(let results):
        self.lastFailures = Dictionary(results.compactMap { result in result.failureCode.map { (result.index, $0) } }) { first, _ in first }
      }
    }
  }

  func discard() async {
    guard canDiscard else { return }
    await perform(.discard) { () async throws(ChatCardRefusal) in try await self.writer.discard(self.proposal, novel: self.context.novel) }
  }

  func openRevert() {
    guard canRevert else { return }
    revert.open(.proposals([proposal]))
  }

  // TurnProposalCard.tsx:181
  var applyTitle: String {
    guard declinedCount > 0 else { return String(localized: "Apply", table: "ChatCards") }
    return String(localized: "Apply \(selected.count) selected", table: "ChatCards")
  }

  private var currentDeclined: Set<Int> {
    declined ?? Set(ops.filter { $0.isGuarded || $0.isJobAction || !$0.isReadable }.map(\.index))
  }

  private func perform(_ write: ChatCardsErrors.Write, _ body: () async throws(ChatCardRefusal) -> Void) async {
    isBusy = true
    notice = nil
    defer { isBusy = false }
    do throws(ChatCardRefusal) {
      try await body()
    } catch {
      notice = ChatCardNotice(error: ChatCardsErrors.presented(error, during: write))
    }
  }

  /// A card decided since, here or on another device, is no longer held conflicted by an apply this model saw refused.
  private func changed(_ snapshot: ChatCardSnapshot) {
    guard snapshot.status != .pending, conflictedOnApply else { return }
    conflictedOnApply = false
    notice = nil
  }
}
