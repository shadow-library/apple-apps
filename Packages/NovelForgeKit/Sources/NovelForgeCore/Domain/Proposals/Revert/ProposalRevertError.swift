import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/classes/app-error-code.ts:166-191 and classes/op-dependency.error.ts:8
public enum ProposalRevertError: ShadowError, Equatable {
  case notFound(UUID)
  case unreadable(UUID)
  case notRevertible
  case invalidIndex(Int)
  case notToggleable(index: Int)
  /// The change's record cannot be read on this device: it may hold an undo, so it is shown and refused, never skipped.
  case changeUnreadable(index: Int)
  case dependents(index: Int, [Int])
  case prerequisites(index: Int, [Int])
  case turnNotApplied
  case conflicted([BaselineMismatch])
  case redoConflicted([BaselineMismatch])
  case inverseDidNotRestore(index: Int)
  case redoDidNotRestore(index: Int)
  /// Changes another device may have applied, whose records have not arrived here, could rely on this one.
  case changesNotSynced([Int])
  /// Changes this card's apply left out whose records have changed since: the author's own edit, or another device's apply still arriving. The author may
  /// accept them as absent (`ProposalRevertContext.acceptingChangedDeclined`).
  case declinedChanged([Int])
  case impactUnavailable
  case apply(index: Int, ApplyError)
  case domain(DomainError)
  case notebook(IdeaRejectionError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .notFound: "RFN_001"
    case .unreadable: "refinement.unreadable_record"
    case .notRevertible: "RFN_007"
    case .invalidIndex: "RFN_011"
    case .notToggleable: "RFN_014"
    case .changeUnreadable: "refinement.change_unreadable"
    case .dependents: "RFN_015"
    case .prerequisites: "RFN_016"
    case .turnNotApplied: "RFN_017"
    case .conflicted: "RFN_006"
    case .redoConflicted: "RFN_003"
    case .inverseDidNotRestore: "RFN_018"
    case .redoDidNotRestore: "refinement.redo_did_not_restore"
    case .changesNotSynced: "refinement.changes_not_synced"
    case .declinedChanged: "refinement.declined_changed"
    case .impactUnavailable: "refinement.impact_unavailable"
    case .apply(_, let error): error.code
    case .domain(let error): error.code
    case .notebook(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notFound: "Refinement proposal not found"
    case .unreadable: "This proposal cannot be read on this device, so its changes are not undone or redone here"
    case .notRevertible: "Proposal is not revertible — it is not applied, has no content ops, or was already reverted"
    case .invalidIndex: "Invalid op selection — indexes must reference ops in the change-set and select at least one"
    case .notToggleable(let index):
      "Change \(index) cannot be undone or redone on its own — only a change a chat turn applied can be; undo the whole proposal instead"
    case .changeUnreadable(let index): "Change \(index) cannot be read on this device, so it is not undone or redone here"
    case .dependents(let index, let indexes): "Other changes from this turn rely on change \(index) — undo changes \(Self.listed(indexes)) first"
    case .prerequisites(let index, let indexes): "Change \(index) relies on changes that are undone — redo changes \(Self.listed(indexes)) first"
    case .turnNotApplied: "This turn’s changes were undone as a whole — a change can be redone only while the rest of its turn is applied"
    case .conflicted: "Revert conflict — an artifact changed since this proposal was applied"
    case .redoConflicted: "Refinement proposal conflicts with the current artifact state — the artifact changed since the proposal was made"
    case .inverseDidNotRestore(let index): "Change \(index) could not be put back exactly as it was before, so nothing was undone"
    case .redoDidNotRestore(let index): "Change \(index) could not be brought back exactly as it was applied, so nothing was redone"
    case .changesNotSynced(let indexes): "Changes \(Self.listed(indexes)) of this turn are still arriving from another device — try again once they have synced"
    case .declinedChanged(let indexes):
      "Changes \(Self.listed(indexes)) were left out when this card was applied, and their records have changed since — they may also be another device’s apply still arriving"
    case .impactUnavailable: "What relies on this change cannot be read on this device right now"
    case .apply(_, let error): error.errorDescription
    case .domain(let error): error.errorDescription
    case .notebook(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  private static func listed(_ indexes: [Int]) -> String {
    indexes.map(String.init).joined(separator: ", ")
  }

  public static func == (left: ProposalRevertError, right: ProposalRevertError) -> Bool {
    switch (left, right) {
    case (.notFound(let first), .notFound(let second)), (.unreadable(let first), .unreadable(let second)): first == second
    case (.notRevertible, .notRevertible), (.turnNotApplied, .turnNotApplied), (.impactUnavailable, .impactUnavailable): true
    case (.invalidIndex(let first), .invalidIndex(let second)), (.notToggleable(let first), .notToggleable(let second)),
      (.changeUnreadable(let first), .changeUnreadable(let second)), (.inverseDidNotRestore(let first), .inverseDidNotRestore(let second)),
      (.redoDidNotRestore(let first), .redoDidNotRestore(let second)):
      first == second
    case (.dependents(let first, let found), .dependents(let second, let other)), (.prerequisites(let first, let found), .prerequisites(let second, let other)):
      first == second && found == other
    case (.conflicted(let first), .conflicted(let second)), (.redoConflicted(let first), .redoConflicted(let second)): first == second
    case (.changesNotSynced(let first), .changesNotSynced(let second)), (.declinedChanged(let first), .declinedChanged(let second)): first == second
    case (.apply(let first, let cause), .apply(let second, let other)): first == second && cause == other
    case (.domain(let first), .domain(let second)): first == second
    case (.notebook(let first), .notebook(let second)): first == second
    case (.store(let first), .store(let second)): first.code == second.code && first.errorDescription == second.errorDescription
    default: false
    }
  }
}
