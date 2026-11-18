import Foundation
import NovelForgeCore

/// A refused write, as the cards explain it: the error's code and the indexes it names (the dependents, prerequisites, changes left out or refused).
nonisolated struct ChatCardRefusal: Error, Equatable, Sendable {
  let code: String
  var indexes: [Int] = []
  var isStore = false
}

nonisolated struct ChatChangeResult: Equatable, Sendable {
  let index: Int
  let status: ProposalChangeStatus
  var failureCode: String?
}

nonisolated enum ChatApplyResult: Equatable, Sendable {
  /// RFN_003: nothing was applied; the indexes touch what changed since the card was staged.
  case conflicted(indexes: [Int])
  case applied([ChatChangeResult])
}

nonisolated struct ChatUndoDependent: Equatable, Sendable {
  /// `plan`, `draft`, `knowledge` or `suggestion` (undo-impact.ts:8).
  let kind: String
  let ref: String
  let chapter: Int?
  let isFinal: Bool
}

nonisolated struct ChatUndoImpact: Equatable, Sendable {
  let dependents: [ChatUndoDependent]
  let finalUnaffected: Int
  var unreadable = 0

  static let none = ChatUndoImpact(dependents: [], finalUnaffected: 0)

  // apps/novel-forge-web/src/features/chat/chat-view.ts:169-175
  static func merged(_ impacts: [ChatUndoImpact]) -> ChatUndoImpact {
    var refs = Set<String>()
    let dependents = impacts.flatMap(\.dependents).filter { refs.insert($0.ref).inserted }
    return ChatUndoImpact(
      dependents: dependents, finalUnaffected: impacts.reduce(0) { $0 + $1.finalUnaffected }, unreadable: impacts.reduce(0) { $0 + $1.unreadable })
  }
}

nonisolated struct ChatRollbackResult: Equatable, Sendable {
  let reverted: [UUID]
  let skipped: [UUID]
  var stoppedAt: UUID?
  var refusal: ChatCardRefusal?
}

/// The proposal writes the cards make, over `CoreChatProposalWriter` in the app and a scripted writer in tests.
protocol ChatProposalWriting: Sendable {
  func apply(_ proposal: UUID, indexes: [Int], novel: UUID) async throws(ChatCardRefusal) -> ChatApplyResult
  func discard(_ proposal: UUID, novel: UUID) async throws(ChatCardRefusal)
  func undo(_ proposal: UUID, index: Int, idea: LedgerRejectionScope?, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> Bool
  func redo(_ proposal: UUID, index: Int, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> Bool
  func revert(_ proposal: UUID, accepting: Set<Int>, novel: UUID) async throws(ChatCardRefusal) -> [Int]
  func rollback(after anchor: UUID, novel: UUID) async throws(ChatCardRefusal) -> ChatRollbackResult
  func impact(of proposal: UUID, index: Int?, novel: UUID) async throws(ChatCardRefusal) -> ChatUndoImpact
}
