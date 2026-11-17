import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

// apps/novel-forge-server/tests/refinement/proposal-apply-op-undo.spec.ts:19-25 with this novel's keys: `kael` is created, `mara` already stands
enum RevertWorld {
  static let kael = #"{"op":"entity.upsert","entityKey":"kael","type":"character","name":"Kael"}"#
  static let kaelEscapes = #"{"op":"milestone.upsert","milestoneKey":"kael-escapes","label":"Kael escapes the ledger house","subjectEntityKey":"kael"}"#
  static let maraNotes = #"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"Mara keeps the slip in her boot.","motivation":"She wants the ledger back."}"#
  static let sources: [OpSource] = [.idea, .idea, .quoted]

  /// The novel with `mara` noted as hiding the slip, and the three-change turn staged as a chat card.
  static func turn(kind: ProposalKind = .chat) async throws -> (book: ChapterBook, id: UUID) {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(notes: "Mara hides the slip."), in: &$0) }
    let id = try await book.stage(kael, kaelEscapes, maraNotes, kind: kind).proposal.id
    return (book, id)
  }
}

extension ChapterBook {
  var revertContext: ProposalRevertContext { ProposalRevertContext(novel: novel, now: clock.now) }

  func applyTurn(_ id: UUID, _ selection: ApplySelection = .whole, sources: [OpSource] = RevertWorld.sources) async throws {
    _ = try await applied(id, selection, context: context(automatic: true, sources: sources))
  }

  @discardableResult
  func undoChange(_ id: UUID, _ index: Int, idea: IdeaUndoChoice = IdeaUndoChoice()) async throws -> ProposalChangeToggle {
    let toggle = try await store.undoProposalChange(id, index: index, idea: idea, context: revertContext)
    try await Projection.expectNoFaults(in: store)
    return toggle
  }

  @discardableResult
  func redoChange(_ id: UUID, _ index: Int) async throws -> ProposalChangeToggle {
    let toggle = try await store.redoProposalChange(id, index: index, context: revertContext)
    try await Projection.expectNoFaults(in: store)
    return toggle
  }

  @discardableResult
  func revertCard(_ id: UUID) async throws -> ProposalRevertResult {
    let result = try await store.revertProposal(id, context: revertContext)
    try await Projection.expectNoFaults(in: store)
    return result
  }

  func undoRefusal(_ id: UUID, _ index: Int) async -> ProposalRevertError? {
    await refusal { [revertContext] store throws(ProposalRevertError) in _ = try await store.undoProposalChange(id, index: index, context: revertContext) }
  }

  func redoRefusal(_ id: UUID, _ index: Int) async -> ProposalRevertError? {
    await refusal { [revertContext] store throws(ProposalRevertError) in _ = try await store.redoProposalChange(id, index: index, context: revertContext) }
  }

  func revertRefusal(_ id: UUID) async -> ProposalRevertError? {
    await refusal { [revertContext] store throws(ProposalRevertError) in _ = try await store.revertProposal(id, context: revertContext) }
  }

  func statuses(_ id: UUID) async throws -> [ProposalChangeStatus?] {
    try await changes(id).map { entry in
      guard case .recorded(let change) = entry else { return nil }
      return change.status.known
    }
  }

  func impact(_ id: UUID, _ index: Int? = nil) async throws -> UndoImpact {
    try await store.undoImpact(of: id, index: index, novel: novel)
  }

  private func refusal(_ body: @Sendable (VaultStore) async throws(ProposalRevertError) -> Void) async -> ProposalRevertError? {
    do throws(ProposalRevertError) {
      try await body(store)
      return nil
    } catch {
      return error
    }
  }
}
