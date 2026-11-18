import Foundation
import NovelForgeCore
import ShadowStore

/// The cards' writes on NovelForgeCore's proposal entry points, with each refusal reduced to its code and the indexes it names.
struct CoreChatProposalWriter: ChatProposalWriting {
  let store: VaultStore
  var now: @Sendable () -> Date = { Date() }

  func apply(_ proposal: UUID, indexes: [Int], novel: UUID) async throws(ChatCardRefusal) -> ChatApplyResult {
    do throws(ProposalApplyError) {
      switch try await store.applyProposal(proposal, selection: .indexes(indexes), context: ProposalApplyContext(novel: novel, now: now())) {
      case .conflicted(let mismatches): return .conflicted(indexes: Array(Set(mismatches.flatMap(\.indexes))).sorted())
      case .applied(let outcomes): return .applied(outcomes.map { ChatChangeResult(index: $0.index, status: $0.status, failureCode: $0.failure?.code) })
      }
    } catch {
      throw Self.refusal(error)
    }
  }

  func discard(_ proposal: UUID, novel: UUID) async throws(ChatCardRefusal) {
    do throws(ProposalDecisionError) {
      try await store.discardProposal(proposal, novel: novel)
    } catch {
      throw ChatCardRefusal(code: error.code, isStore: error.isStore)
    }
  }

  func undo(_ proposal: UUID, index: Int, idea: LedgerRejectionScope?, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> Bool {
    let choice = IdeaUndoChoice(scope: idea ?? .notNow)
    return try await reverting { () async throws(ProposalRevertError) in
      try await store.undoProposalChange(proposal, index: index, idea: choice, context: context(novel, accepting)).changed
    }
  }

  func redo(_ proposal: UUID, index: Int, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> Bool {
    try await reverting { () async throws(ProposalRevertError) in try await store.redoProposalChange(proposal, index: index, context: context(novel, accepting)).changed }
  }

  func revert(_ proposal: UUID, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> [Int] {
    try await reverting { () async throws(ProposalRevertError) in try await store.revertProposal(proposal, context: context(novel, accepting)).reverted }
  }

  func rollback(after anchor: UUID, novel: UUID) async throws(ChatCardRefusal) -> ChatRollbackResult {
    try await reverting { () async throws(ProposalRevertError) in
      let result = try await store.rollbackProposals(after: anchor, context: context(novel, []))
      return ChatRollbackResult(
        reverted: result.reverted.map(\.proposal), skipped: result.skipped, stoppedAt: result.stoppedAt, refusal: result.conflict.map(Self.refusal))
    }
  }

  func impact(of proposal: UUID, index: Int?, novel: UUID) async throws(ChatCardRefusal) -> ChatUndoImpact {
    try await reverting { () async throws(ProposalRevertError) in
      let impact = try await store.undoImpact(of: proposal, index: index, novel: novel)
      let dependents = impact.dependents.map { ChatUndoDependent(kind: $0.kind.rawValue, ref: $0.ref, chapter: $0.chapter, isFinal: $0.final) }
      return ChatUndoImpact(dependents: dependents, finalUnaffected: impact.finalUnaffected, unreadable: impact.unreadable)
    }
  }

  private func context(_ novel: UUID, _ accepting: Set<Int>) -> ProposalRevertContext {
    ProposalRevertContext(novel: novel, now: now(), acceptingChangedDeclined: accepting)
  }

  private func reverting<T>(_ body: () async throws(ProposalRevertError) -> T) async throws(ChatCardRefusal) -> T {
    do throws(ProposalRevertError) {
      return try await body()
    } catch {
      throw Self.refusal(error)
    }
  }

  private static func refusal(_ error: ProposalApplyError) -> ChatCardRefusal {
    switch error {
    case .changeRefused(let indexes, _): ChatCardRefusal(code: error.code, indexes: indexes)
    case .action(let index, _): ChatCardRefusal(code: error.code, indexes: [index])
    case .store: ChatCardRefusal(code: error.code, isStore: true)
    case .domain(.store): ChatCardRefusal(code: error.code, isStore: true)
    default: ChatCardRefusal(code: error.code)
    }
  }

  private static func refusal(_ error: ProposalRevertError) -> ChatCardRefusal {
    switch error {
    case .dependents(_, let indexes), .prerequisites(_, let indexes), .changesNotSynced(let indexes), .declinedChanged(let indexes):
      ChatCardRefusal(code: error.code, indexes: indexes)
    case .conflicted(let mismatches), .redoConflicted(let mismatches): ChatCardRefusal(code: error.code, indexes: Array(Set(mismatches.flatMap(\.indexes))).sorted())
    case .invalidIndex(let index), .notToggleable(let index), .changeUnreadable(let index), .inverseDidNotRestore(let index), .redoDidNotRestore(let index),
      .apply(let index, _):
      ChatCardRefusal(code: error.code, indexes: [index])
    case .store, .domain(.store): ChatCardRefusal(code: error.code, isStore: true)
    default: ChatCardRefusal(code: error.code)
    }
  }
}

extension ProposalDecisionError {
  fileprivate var isStore: Bool {
    guard case .store = self else { return false }
    return true
  }
}
