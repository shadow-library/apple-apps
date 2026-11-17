import Foundation
import ShadowCore
import ShadowStore

/// An applied card with what each index amounts to on this device, read by the undo, redo and revert of its changes.
struct ProposalTurn: Sendable {
  let proposal: ProposalRecord
  let entries: [ProposalChangeEntry]

  var ops: [ChangeOp?] { proposal.card.ops }

  // apps/novel-forge-server/src/modules/refinement/proposal-revert.service.ts:87-92 (RFN_001)
  static func load<Transaction: StateReading & ~Copyable>(_ id: UUID, novel: UUID, in transaction: borrowing Transaction) throws(ProposalRevertError) -> ProposalTurn {
    let reading = try revertStore { () throws(StoreError) in try ProposalRecord.read(id: id, in: transaction) }
    switch reading {
    case .absent: throw .notFound(id)
    case .unreadable: throw .unreadable(id)
    case .readable(let entry):
      guard entry.record.novel == novel else { throw .notFound(id) }
      let entries = try revertStore { () throws(StoreError) in try ProposalChangeRecord.changes(of: entry.record, in: transaction) }
      return ProposalTurn(proposal: entry.record, entries: entries)
    }
  }

  var isApplied: Bool { proposal.decision == .known(.applied) }

  /// apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:30 (PER_OP_UNDO_KINDS) and proposal-apply.service.ts:177: only an automatic apply
  /// of a chat or hub card keeps changes that are undone and redone one at a time.
  var togglesPerChange: Bool {
    guard let kind = proposal.card.kind.known, kind == .chat || kind == .hub else { return false }
    return proposal.application?.automatic == true
  }

  func op(at index: Int) -> ChangeOp? {
    ops.indices.contains(index) ? ops[index] : nil
  }

  func contentOp(at index: Int) -> ChangeOp? {
    op(at: index).flatMap { isActionOp($0) ? nil : $0 }
  }

  func source(of index: Int) -> OpSource? {
    guard let sources = proposal.application?.sources, sources.indices.contains(index) else { return nil }
    return sources[index].known
  }

  func undoable(_ index: Int) -> (change: ProposalChangeRecord, undo: ProposalChangeUndo)? {
    guard entries.indices.contains(index), contentOp(at: index) != nil, case .recorded(let change) = entries[index], let undo = change.undo else { return nil }
    return (change, undo)
  }

  /// proposal-revert.service.ts:225-226: the content changes holding an undo, by their status.
  func indexes(_ status: ProposalChangeStatus) -> [Int] {
    entries.indices.filter { undoable($0)?.change.status == .known(status) }
  }

  /// Content indexes whose change this device cannot settle: unreadable, awaiting its record, read as declined (a concurrent applier's record may still be on
  /// its way), or recorded with a status this version does not know.
  var unsettled: [(index: Int, entry: ProposalChangeEntry)] {
    entries.enumerated().compactMap { index, entry in
      guard contentOp(at: index) != nil else { return nil }
      switch entry {
      case .unreadable, .awaiting, .declined: return (index, entry)
      case .recorded(let change) where change.status.known == nil: return (index, entry)
      case .recorded, .notApplied: return nil
      }
    }
  }

  /// proposal-revert.service.ts:222-232; every content index takes its place in the apply order, so a change recorded by another applier keeps its position.
  var graph: AppliedOpGraph {
    let content = ops.indices.filter { contentOp(at: $0) != nil }
    return AppliedOpGraph(ops: ops, baseline: proposal.card.baseline, order: ApplyFrame.applyOrder(ops, content))
  }

  /// The unsettled indexes that may have been applied. `waiting` holds those awaiting their record, unreadable, or of an unknown status; `declinedChanged`
  /// those read as declined whose records, outside `guarded`, no longer stand as the card's baseline recorded them: left out by this card's apply, yet
  /// possibly another device's apply still arriving. A declined index whose records still stand, or that the author accepted as changed, counts as absent.
  /// Refs in `guarded` are covered by the operation's own state guard.
  func possiblyApplied(guarding guarded: Set<JSString>, accepting accepted: Set<Int>, novel: UUID, in transaction: borrowing WriteTransaction)
    throws(ProposalRevertError) -> PossiblyApplied
  {
    var found = PossiblyApplied()
    for (index, entry) in unsettled {
      guard case .declined = entry, let op = contentOp(at: index) else {
        found.waiting.append(index)
        continue
      }
      if accepted.contains(index) { continue }
      let refs = changeSetRefs([op]).filter { !guarded.contains(JSString($0)) }
      let current = try revertStore { () throws(StoreError) in try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction) }
      let absent = refs.allSatisfy { ref in
        guard let recorded = proposal.card.baseline[ref], let now = current[JSString(ref)] else { return false }
        return recorded.matches(now)
      }
      if !absent { found.declinedChanged.append(index) }
    }
    return found
  }

  /// The passage rewrites `leader`'s revision carried, through `CarriedRewrites` over the changes every applier recorded applied or reverted; a rewrite that
  /// several changes may have carried (concurrent appliers grouped its chapter differently) is never among them, so a redo does not replay it.
  func carried(by leader: Int) -> [Int] {
    var recorded = [Int]()
    var holdingUndo = Set<Int>()
    for (index, entry) in entries.enumerated() {
      guard case .recorded(let change) = entry, change.status == .known(.applied) || change.status == .known(.reverted) else { continue }
      recorded.append(index)
      if change.undo != nil { holdingUndo.insert(index) }
    }
    return CarriedRewrites.carriers(of: proposal.card.changeSet, recorded: recorded, holdingUndo: holdingUndo).filter { $0.value == [leader] }.keys.sorted()
  }

  func changeRef(_ index: Int) throws(ProposalRevertError) -> EntityRef {
    do throws(NovelForgeKeyError) {
      return try ProposalChangeRecord.ref(novel: proposal.novel, proposal: proposal.id, index: index)
    } catch {
      throw .store(.invalidChange(error.errorDescription ?? error.code))
    }
  }
}

struct PossiblyApplied: Sendable, Equatable {
  var waiting = [Int]()
  var declinedChanged = [Int]()

  var all: [Int] { waiting + declinedChanged }

  /// Refuses when any of `indexes` is unsettled: `changesNotSynced` before `declinedChanged`, which the author may accept.
  func refuse(_ indexes: [Int]) throws(ProposalRevertError) {
    let unsynced = indexes.filter(waiting.contains).sorted()
    if !unsynced.isEmpty { throw .changesNotSynced(unsynced) }
    let changed = indexes.filter(declinedChanged.contains).sorted()
    if !changed.isEmpty { throw .declinedChanged(changed) }
  }
}

func revertStore<T>(_ body: () throws(StoreError) -> T) throws(ProposalRevertError) -> T {
  do throws(StoreError) {
    return try body()
  } catch {
    throw .store(error)
  }
}
