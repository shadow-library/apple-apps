import Foundation
import ShadowCore
import ShadowStore

extension UndoImpacts {
  /// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:347-354 for the whole card (its applied changes), :361-370 for change `index` alone,
  /// which is refused (RFN_014) wherever its undo would be.
  static func impact(proposal id: UUID, index: Int?, novel: UUID, in transaction: ReadTransaction) throws(ProposalRevertError) -> UndoImpact {
    let turn = try ProposalTurn.load(id, novel: novel, in: transaction)
    guard turn.isApplied else { throw .notRevertible }
    let changed: [(op: ChangeOp, undo: ProposalChangeUndo)]
    if let index {
      guard turn.entries.indices.contains(index) else { throw .invalidIndex(index) }
      if case .unreadable = turn.entries[index] { throw .changeUnreadable(index: index) }
      guard turn.togglesPerChange, let op = turn.contentOp(at: index), let recorded = turn.undoable(index), recorded.change.status == .known(.applied) else {
        throw .notToggleable(index: index)
      }
      changed = [(op, recorded.undo)]
    } else {
      changed = turn.indexes(.applied).compactMap { index in
        guard let op = turn.contentOp(at: index), let undo = turn.undoable(index)?.undo else { return nil }
        return (op, undo)
      }
      guard !changed.isEmpty else { throw .notRevertible }
    }
    let refs = changeSetRefs(changed.map(\.op))
    let removed = changed.filter { $0.undo.inverse["op"]?.stringValue?.jsEndsWith(".remove") == true }.flatMap { changeSetRefs([$0.op]) }
    let (rows, unreadable) = try ImpactRowLoader.rows(changedRefs: refs, excluding: id, novel: novel, in: transaction)
    var impact = impact(undoneChange(refs, removed: removed), rows: rows)
    impact.unreadable = unreadable
    return impact
  }
}

// undo-impact.ts:165-196
enum ImpactRowLoader {
  static func rows(changedRefs: [String], excluding proposal: UUID, novel: UUID, in transaction: ReadTransaction) throws(ProposalRevertError)
    -> (rows: ImpactRows, unreadable: Int)
  {
    let plans = try revertStore { () throws(StoreError) in try ChapterPlanRecord.listing(novel: novel, in: transaction) }
    let drafts = try revertStore { () throws(StoreError) in try DraftRecord.listing(novel: novel, in: transaction) }
    let finals = try revertStore { () throws(StoreError) in try FinalChapterRecord.listing(novel: novel, in: transaction) }
    let proposals = try revertStore { () throws(StoreError) in
      ProposalRecord.collecting(try transaction.states(ofKind: ProposalRecord.kind.entityKind, scope: .vault), owner: novel)
    }

    let finalChapters = Set(finals.entries.map(\.record.chapter))
    let draftChapters = Set(drafts.live.map(\.chapter)).union(finalChapters)
    var rows = ImpactRows()
    rows.plans = plans.live.map { ImpactPlan(chapter: $0.chapter, references: references(of: $0.content)) }
    rows.drafts = draftChapters.sorted().map { ImpactDraft(chapter: $0, isFinal: finalChapters.contains($0)) }
    rows.knowledge = try knowledge(changedRefs: changedRefs, novel: novel, in: transaction)
    rows.suggestions = proposals.live.filter { $0.id != proposal && $0.decision == .known(.pending) }.map { pending in
      ImpactSuggestion(id: pending.id, references: pending.card.baseline.refs + pending.card.ops.compactMap { $0 }.flatMap(opReferences))
    }
    return (rows, plans.unreadable + drafts.unreadable + finals.unreadable + proposals.unreadable)
  }

  /// undo-impact.ts:80-92 (planReferences) through write-policy.ts:368 (opReferences, `brief.update`): the plan's volume, every entity it names as a POV or a
  /// learner, the secrets it teaches, the milestones it claims and the Story Bible pages it cites.
  static func references(of plan: ChapterPlanContent) -> [String] {
    let contract = plan.contract
    let entities = [plan.pov] + (plan.scenes ?? []).map(\.scene.pov) + contract.pov.map(Optional.some) + contract.learns.map { Optional.some($0.reveal.entityKey) }
    return (named(plan.volume).map { ["volume:\($0)"] } ?? []) + entities.compactMap { named($0).map { "entity:\($0)" } }
      + contract.learns.map { "fact:\($0.reveal.factKey)" } + contract.claimedMilestones.map { "milestone:\($0)" } + (plan.contextRefs ?? []).map(asChangeSetRef)
  }

  private static func named(_ key: String?) -> String? {
    guard let key, !key.isEmpty else { return nil }
    return key
  }

  // undo-impact.ts:166-190: the knowledge rows about a changed secret or a changed character, as the derived ledger holds them
  private static func knowledge(changedRefs: [String], novel: UUID, in transaction: ReadTransaction) throws(ProposalRevertError) -> [ImpactKnowledge] {
    let facts = Set(keys(changedRefs, "fact:").map { JSString($0) })
    let entities = Set(keys(changedRefs, "entity:").map { JSString($0) })
    guard !facts.isEmpty || !entities.isEmpty else { return [] }
    let ledger = try revertStore { () throws(StoreError) in try KnowledgeLedger.load(novel, in: transaction) }
    guard let entries = ledger.entries.value else { throw .impactUnavailable }
    return entries.filter { facts.contains(JSString($0.fact)) || entities.contains(JSString($0.entity)) }.map { entry in
      ImpactKnowledge(fact: entry.fact, entity: entry.entity, learnedInChapter: entry.chapter, isCommitted: entry.status == .committed)
    }
  }

  // undo-impact.ts:161
  private static func keys(_ refs: [String], _ prefix: String) -> [String] {
    refs.filter { $0.jsStartsWith(prefix) }.map { $0.jsSlice(prefix.jsLength) }
  }
}
