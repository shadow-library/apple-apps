import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore

/// TurnProposalCard.tsx:115, with `conflicted` derived at read time and `reverted` once every content change is undone (proposal.service.ts:297).
enum ChatCardStatus: Equatable {
  case pending
  case conflicted
  case applied
  case reverted
  case discarded
  case superseded
  /// Neither the card nor its derived state has arrived on this device yet.
  case absent
  case unknown
}

/// One proposal, re-read on every commit; each index reads as the change history does, so a carried rewrite stands as its leader does.
nonisolated struct ChatCardSnapshot: Equatable, Sendable {
  let proposal: UUID
  let state: ProposalState?
  let card: ProposalCard?
  let decision: StoredEnum<ProposalDecision>?
  let application: ProposalApplication?
  let change: ChatChange?
  /// The code each failed change or action recorded.
  let failures: [Int: String]
  let conflict: ChatCardConflict?
  /// The proposal's derived state is faulted on this device.
  let isUnavailable: Bool

  static func load(_ proposal: UUID, in transaction: ReadTransaction) throws -> ChatCardSnapshot {
    let derived = try ChatProposal.load(proposal, in: transaction).proposal
    let detail = derived.value ?? nil
    let record = try ProposalRecord.read(id: proposal, in: transaction).entry?.record
    var failures = [Int: String]()
    if let record {
      for case .recorded(let change) in try ProposalChangeRecord.changes(of: record, in: transaction) {
        guard change.status == .known(.failed) || change.actionOutcome == .known(.failed), let code = change.result?.result?["code"]?.stringValue else { continue }
        failures[change.index] = code
      }
    }
    let decision = record?.decision ?? detail?.state.decision
    var conflict: ChatCardConflict?
    if decision == .known(.pending), let novel = record?.novel {
      conflict = try ChatWaitingOnYou.load(novel, in: transaction).contents.value?.conflicted.first { $0.state.proposal == proposal }?.conflict
    }
    // The entries do not depend on the apply clock or the session, which this read does not need.
    let change = detail.map { ChatChange(applied: $0.state.staged, state: $0.state, session: .none, record: record, rows: $0.entries) }
    return ChatCardSnapshot(
      proposal: proposal, state: detail?.state, card: record?.card, decision: decision, application: record?.application, change: change, failures: failures,
      conflict: conflict, isUnavailable: derived.isUnavailable)
  }

  var ops: [ChatOp] { card.map(ChatOp.ops) ?? [] }

  var isAutomatic: Bool { application?.automatic ?? false }

  var status: ChatCardStatus {
    switch decision {
    case .known(.pending)?: conflict == nil ? .pending : .conflicted
    case .known(.applied)?: change?.isReverted == true ? .reverted : .applied
    case .known(.discarded)?: .discarded
    case .known(.superseded)?: .superseded
    case .unknown?: .unknown
    case nil: .absent
    }
  }

  func entry(_ index: Int) -> ChatChangeEntry? { change?.entries.first { $0.index == index } }

  func state(of index: Int) -> ProposalChangeEntryState? { entry(index)?.state }

  /// progress-panel-view.ts:293: Forge's idea by the source the first applier recorded for it.
  func isIdea(_ index: Int) -> Bool {
    guard let sources = application?.sources, sources.indices.contains(index) else { return false }
    return sources[index] == .known(.idea)
  }

  /// A content change that stands applied and holds its undo (proposal.service.ts:297).
  var isRevertible: Bool { change?.isRevertible == true }
}
