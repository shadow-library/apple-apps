import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

nonisolated struct ChatChangesSnapshot: Equatable, Sendable {
  let page: Derived<ChatChangePage>
}

/// What the last undo or rollback of the history did (apps/novel-forge-web/src/routes/novels/$novelId/chat.tsx:72-89).
enum ChatChangesReport: Equatable {
  case reverted
  case rolledBack(ChatRollbackResult)

  var isStopped: Bool {
    guard case .rolledBack(let result) = self else { return false }
    return result.stoppedAt != nil || result.refusal != nil
  }
}

/// chat.tsx:64-152; the window grows a page at a time, so the pages already shown stay live.
@MainActor
@Observable
final class ChatChangesModel {
  let context: NovelContext
  let revert: ChatRevertFlow
  private(set) var limit: Int
  private(set) var generation = 0
  private var finished: ChatChangesReport?
  private var dismissed: ChatRollbackResult?
  private let pageSize: Int
  private let observer = ReadObserver<ChatChangesSnapshot>()

  // apps/novel-forge-server/src/modules/refinement/proposal.service.ts:262 pages 30 at a time
  init(context: NovelContext, writer: any ChatProposalWriting, pageSize: Int = 30) {
    self.context = context
    self.pageSize = pageSize
    limit = pageSize
    revert = ChatRevertFlow(novel: context.novel, writer: writer)
    revert.onFinished = { [weak self] outcome in self?.finish(outcome) }
  }

  var state: Loadable<ChatChangesSnapshot> { observer.state }

  var page: ChatChangePage? { state.value?.page.value }

  var changes: [ChatChange] { page?.changes ?? [] }

  var hasMore: Bool { limit < page?.total ?? 0 }

  var isLocked: Bool { revert.isRunning }

  /// A rollback that stopped keeps what it undid before the stop, which the flow holds until it opens again.
  var report: ChatChangesReport? {
    if let finished { return finished }
    guard let partial = revert.rolledBack, partial.refusal != nil, partial != dismissed else { return nil }
    return .rolledBack(partial)
  }

  func observe() async {
    let (store, query) = (context.store, ChatChangeHistoryQuery(novel: context.novel, limit: limit))
    await observer.run { store.observeReads { transaction in ChatChangesSnapshot(page: try ChatChangeHistory.load(query, in: transaction).page) } }
  }

  func retry() {
    generation += 1
  }

  func showMore() {
    limit += pageSize
    generation += 1
  }

  /// chat.tsx:116: a change whose content stands applied with its undo.
  func canRevert(_ change: ChatChange) -> Bool { change.isRevertible && !isLocked }

  /// chat.tsx:121: any change not wholly undone may be the point the novel goes back to.
  func canRollBack(to change: ChatChange) -> Bool { !change.isReverted && !isLocked }

  func revert(_ change: ChatChange) {
    guard canRevert(change) else { return }
    finished = nil
    revert.open(.proposals([change.state.proposal]))
  }

  func rollBack(to change: ChatChange) {
    guard canRollBack(to: change) else { return }
    finished = nil
    revert.open(.rollback(after: change.state.proposal))
  }

  func dismissReport() {
    finished = nil
    dismissed = revert.rolledBack
  }

  private func finish(_ outcome: ChatRevertFlow.Outcome) {
    switch outcome {
    case .reverted: finished = .reverted
    case .rolledBack(let result): finished = .rolledBack(result)
    case .undone: finished = nil
    }
  }
}
