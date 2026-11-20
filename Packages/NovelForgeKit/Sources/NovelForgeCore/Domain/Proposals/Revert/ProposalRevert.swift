import Foundation
import ShadowCore
import ShadowStore
import ShadowText

public struct ProposalRevertContext: Sendable {
  let novel: UUID
  var now: Date
  /// apply/unrestricted-raise.ts:18: asked only when a redone op raises a plan to unrestricted.
  var unrestrictedAvailable = UnrestrictedWriting.isAvailable
  /// Indexes this card's apply left out whose records changed since, which the author confirmed to treat as never applied (`declinedChanged`).
  var acceptingChangedDeclined: Set<Int> = []

  public init(novel: UUID, now: Date, acceptingChangedDeclined: Set<Int> = []) {
    self.novel = novel
    self.now = now
    self.acceptingChangedDeclined = acceptingChangedDeclined
  }
}

// apps/novel-forge-server/src/modules/refinement/proposal-op-undo.service.ts:22-23: an undone idea is turned down, `not_now` unless the author chose a scope
public struct IdeaUndoChoice: Sendable, Equatable {
  var scope: LedgerRejectionScope = .notNow
  var why: String?

  public init(scope: LedgerRejectionScope = .notNow, why: String? = nil) {
    self.scope = scope
    self.why = why
  }
}

// proposal-revert.service.ts:39-49
public struct ProposalChangeToggle: Sendable, Equatable {
  let index: Int
  /// False when the change already stood as asked: undo and redo are idempotent.
  public let changed: Bool
  let source: OpSource?
  let refs: [String]
  var rejection: NotebookEntryRecord?
  var withdrawals: [NotebookWithdrawalRecord] = []
}

public struct ProposalRevertResult: Sendable, Equatable {
  /// The indexes undone, in the order their inverses ran.
  public let reverted: [Int]
  let refs: [String]
}

/// apps/novel-forge-server/src/modules/refinement/proposal-revert.service.ts and proposal-op-undo.service.ts. Every guard reads the change's own record:
/// `undo.postState` before an undo, the `undone_state` register before a redo, compared with `ArtifactState.matches` so an unreadable record never matches.
/// A whole revert is each applied change undone, latest first, so a redo after it stays possible (RFN_017 is reached only while the card is not applied).
/// Actions hold no undo and are never undone. Not ported: user feedback rows (:122, :156-158, :189-191) and the organise decision (:113).
enum ProposalRevert {
  // proposal-op-undo.service.ts:12
  static let redoneReason = "The author brought the change back after undoing it."

  // proposal-revert.service.ts:133-164 and proposal-op-undo.service.ts:22-28
  static func undo(
    proposal id: UUID, index: Int, idea: IdeaUndoChoice = IdeaUndoChoice(), context: ProposalRevertContext, in transaction: inout WriteTransaction
  ) throws(ProposalRevertError) -> ProposalChangeToggle {
    let turn = try ProposalTurn.load(id, novel: context.novel, in: transaction)
    let (op, change, undo) = try toggleable(index, of: turn, notApplied: .notRevertible)
    let refs = changeSetRefs([op])
    guard change.status == .known(.applied) else { return ProposalChangeToggle(index: index, changed: false, source: turn.source(of: index), refs: refs) }

    try settle(chapters: DraftHandlers.draftChapters(of: [op]) + inverseChapters(undo), index: index, novel: context.novel, in: &transaction)
    let applied = turn.indexes(.applied)
    let possible = try turn.possiblyApplied(
      guarding: Set(refs.map { JSString($0) }), accepting: context.acceptingChangedDeclined, novel: context.novel, in: transaction)
    let dependents = turn.graph.dependents(index, applied: applied + possible.all)
    let known = dependents.filter(applied.contains)
    if !known.isEmpty { throw .dependents(index: index, known) }
    try possible.refuse(dependents)

    var overlay = PlanOverlay()
    let undoContext = ApplyContext(novel: context.novel, intent: .undo, now: context.now)
    try undoStep(index, op: op, undo: undo, turn: turn, context: undoContext, overlay: &overlay, in: &transaction)
    try enforce(overlay, index: index, novel: context.novel, in: transaction)
    var toggle = ProposalChangeToggle(index: index, changed: true, source: turn.source(of: index), refs: refs)
    if toggle.source == .idea {
      toggle.rejection = try notebook { () throws(IdeaRejectionError) in
        try NotebookIdeaRejections.reject(proposal: id, opIndex: index, scope: idea.scope, why: idea.why, novel: context.novel, in: &transaction)
      }
    }
    return toggle
  }

  // proposal-revert.service.ts:167-197 and proposal-op-undo.service.ts:30-34. The stored inverse is content-based, so it undoes the redone change again and
  // the first-writer-wins `undo` is never rewritten; the redo must land on the state the apply left (`undo.postState`), or the change could not be undone
  // again. Deviation: where the reference recaptures the inverse (:183-185), a redo that lands elsewhere — a volume without an ordinal placed after a volume
  // created since, a new plan's nearest volume — is refused (`redoDidNotRestore`); the author applies it again from a new card.
  static func redo(proposal id: UUID, index: Int, context: ProposalRevertContext, in transaction: inout WriteTransaction) throws(ProposalRevertError)
    -> ProposalChangeToggle
  {
    let turn = try ProposalTurn.load(id, novel: context.novel, in: transaction)
    let (op, change, undo) = try toggleable(index, of: turn, notApplied: .turnNotApplied)
    let carried = turn.carried(by: index)
    let refs = changeSetRefs([op])
    guard change.status == .known(.reverted) else { return ProposalChangeToggle(index: index, changed: false, source: turn.source(of: index), refs: refs) }

    try settle(chapters: DraftHandlers.draftChapters(of: [op]), index: index, novel: context.novel, in: &transaction)
    let undone = turn.indexes(.reverted)
    let possible = try turn.possiblyApplied(
      guarding: Set(refs.map { JSString($0) }), accepting: context.acceptingChangedDeclined, novel: context.novel, in: transaction)
    let prerequisites = turn.graph.prerequisites(index, undone: undone + possible.all, applied: turn.indexes(.applied))
    let known = prerequisites.filter(undone.contains)
    if !known.isEmpty { throw .prerequisites(index: index, known) }
    try possible.refuse(prerequisites)

    let current = try states(refs, novel: context.novel, in: transaction)
    let moved = mismatches(refs, expected: change.undoneState ?? ArtifactStates(), actual: current, index: index)
    if !moved.isEmpty { throw .redoConflicted(moved) }

    let call = redoCall(op, carried: carried, of: turn)
    let raise = context.unrestrictedAvailable && ProposalApply.raisesToUnrestricted(op)
    let redoContext = ApplyContext(novel: context.novel, intent: .redo, now: context.now, unrestrictedRaise: raise)
    let step = try performing(index) { () throws(ApplyError) in try ApplyFrame.perform(call, context: redoContext, in: &transaction) }
    try enforce(PlanOverlay(step.planEdits), index: index, novel: context.novel, in: transaction)
    if !mismatches(refs, expected: undo.postState, actual: step.postState, index: index).isEmpty { throw .redoDidNotRestore(index: index) }
    let changeRef = try turn.changeRef(index)
    _ = try revertStore { () throws(StoreError) in try ProposalChangeRecord.recordRedo(changeRef, in: &transaction) }

    var toggle = ProposalChangeToggle(index: index, changed: true, source: turn.source(of: index), refs: refs)
    if toggle.source == .idea {
      toggle.withdrawals = try notebook { () throws(IdeaRejectionError) in
        try NotebookIdeaRejections.withdrawRejection(of: op, reason: redoneReason, novel: context.novel, in: &transaction)
      }
    }
    return toggle
  }

  // proposal-revert.service.ts:84-130: every applied change undone, latest first with removals last (:111), each over the state the apply left it; records
  // that moved since refuse the whole revert (RFN_006), all of them listed (:100-107), with nothing written. An unreadable change, or one awaiting its record,
  // refuses it too.
  static func revert(proposal id: UUID, context: ProposalRevertContext, in transaction: inout WriteTransaction) throws(ProposalRevertError) -> ProposalRevertResult {
    let turn = try ProposalTurn.load(id, novel: context.novel, in: transaction)
    guard turn.isApplied else { throw .notRevertible }
    var awaiting = [Int]()
    for (index, entry) in turn.unsettled {
      switch entry {
      case .unreadable, .recorded: throw .changeUnreadable(index: index)
      case .awaiting: awaiting.append(index)
      case .declined, .notApplied: continue
      }
    }
    if !awaiting.isEmpty { throw .changesNotSynced(awaiting) }
    let live = turn.indexes(.applied)
    guard !live.isEmpty else { throw .notRevertible }

    var steps = [RevertStep]()
    for index in ApplyFrame.applyOrder(turn.ops, live).reversed() {
      guard let op = turn.contentOp(at: index), let undo = turn.undoable(index)?.undo else { continue }
      steps.append(RevertStep(index: index, op: op, undo: undo, inverseType: try inverseType(undo, index: index)))
    }
    let chapters = steps.flatMap { DraftHandlers.draftChapters(of: [$0.op]) + inverseChapters($0.undo) }
    try settle(chapters: chapters, index: steps.first?.index ?? 0, novel: context.novel, in: &transaction)

    let refs = changeSetRefs(steps.map(\.op))
    let stale = try staleRefs(steps, novel: context.novel, in: transaction)
    if !stale.isEmpty { throw .conflicted(stale) }
    let possible = try turn.possiblyApplied(
      guarding: Set(refs.map { JSString($0) }), accepting: context.acceptingChangedDeclined, novel: context.novel, in: transaction)
    let graph = turn.graph
    try possible.refuse(Array(Set(live.flatMap { graph.dependents($0, applied: live + possible.all) })))

    var overlay = PlanOverlay()
    let undoContext = ApplyContext(novel: context.novel, intent: .undo, now: context.now)
    let ordered = ApplyFrame.removalsLast(steps) { $0.inverseType }
    for step in ordered { try undoStep(step.index, op: step.op, undo: step.undo, turn: turn, context: undoContext, overlay: &overlay, in: &transaction) }
    try enforce(overlay, index: ordered.last?.index ?? 0, novel: context.novel, in: transaction)
    return ProposalRevertResult(reverted: ordered.map(\.index), refs: refs)
  }

  private struct RevertStep {
    let index: Int
    let op: ChangeOp
    let undo: ProposalChangeUndo
    let inverseType: OpType
  }

  /// Each ref against the post-state of the latest applied change that wrote it (`steps` run latest first), so the conflict lists every moved record.
  private static func staleRefs(_ steps: [RevertStep], novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalRevertError) -> [BaselineMismatch] {
    let current = try states(changeSetRefs(steps.map(\.op)), novel: novel, in: transaction)
    var seen = Set<JSString>()
    var stale = [BaselineMismatch]()
    for step in steps {
      let latest = changeSetRefs([step.op]).filter { seen.insert(JSString($0)).inserted }
      stale += mismatches(latest, expected: step.undo.postState, actual: current, index: step.index)
    }
    return stale
  }

  // proposal-revert.service.ts:199-216 (RFN_011, RFN_014): a change toggles on its own only when it is a content change of an automatic chat or hub apply
  // holding an undo, applied or undone
  private static func toggleable(_ index: Int, of turn: ProposalTurn, notApplied: ProposalRevertError) throws(ProposalRevertError)
    -> (op: ChangeOp, change: ProposalChangeRecord, undo: ProposalChangeUndo)
  {
    guard turn.entries.indices.contains(index) else { throw .invalidIndex(index) }
    if case .unreadable = turn.entries[index] { throw .changeUnreadable(index: index) }
    guard turn.isApplied else { throw notApplied }
    guard turn.togglesPerChange, let op = turn.contentOp(at: index), let recorded = turn.undoable(index),
      recorded.change.status == .known(.applied) || recorded.change.status == .known(.reverted)
    else { throw .notToggleable(index: index) }
    return (op, recorded.change, recorded.undo)
  }

  /// One change's inverse over the state its apply (or its redo) left: refused (RFN_006) when a record moved since, and (RFN_018) when the inverse does not
  /// land on the state the apply found. Throwing aborts the whole transaction, so nothing is written.
  private static func undoStep(
    _ index: Int, op: ChangeOp, undo: ProposalChangeUndo, turn: ProposalTurn, context: ApplyContext, overlay: inout PlanOverlay, in transaction: inout WriteTransaction
  ) throws(ProposalRevertError) {
    let refs = changeSetRefs([op])
    let stale = mismatches(refs, expected: undo.postState, actual: try states(refs, novel: context.novel, in: transaction), index: index)
    if !stale.isEmpty { throw .conflicted(stale) }
    let inverse = try inverseObject(undo, index: index)
    let step = try performing(index) { () throws(ApplyError) in
      try ApplyFrame.perform(.op(op), context: context, in: &transaction) {
        (_: ContentCall, context: ApplyContext, transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome in
        try undoHandler(inverse, context: context, in: &transaction)
      }
    }
    overlay.append(step.planEdits)
    if !mismatches(refs, expected: undo.priorState, actual: step.postState, index: index).isEmpty { throw .inverseDidNotRestore(index: index) }
    let changeRef = try turn.changeRef(index)
    _ = try revertStore { () throws(StoreError) in
      try ProposalChangeRecord.recordUndo(changeRef, undoneState: ArtifactStates(step.postState), in: &transaction)
    }
  }

  // proposal-revert.service.ts:148 applies the inverse as an op; here each handler file's undo entry point writes it back verbatim
  private static func undoHandler(_ inverse: OrderedJSONObject, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    guard let type = OpFields(record: inverse).string("op").flatMap({ OpType(exactly: $0) }) else { throw .refused(.malformedInverse) }
    switch ApplyFrame.handlerFile(for: type) {
    case .story?: return try StoryHandlers.undo(inverse, context: context, in: &transaction)
    case .bible?: return try BibleHandlers.undo(inverse, context: context, in: &transaction)
    case .plan?: return try PlanHandlers.undo(inverse, context: context, in: &transaction)
    case .draft?: return try DraftHandlers.undo(inverse, context: context, in: &transaction)
    case .inline?, nil: throw .refused(.malformedInverse)
    }
  }

  // proposal-apply.service.ts:173-176: a redone rewrite brings back every rewrite its revision carried, as the apply wrote them
  private static func redoCall(_ op: ChangeOp, carried: [Int], of turn: ProposalTurn) -> ContentCall {
    guard case .draftRewritePassage(let first) = op.operation else { return .op(op) }
    let rest = carried.compactMap { index -> DraftRewritePassage? in
      guard case .draftRewritePassage(let rewrite)? = turn.contentOp(at: index)?.operation else { return nil }
      return rewrite
    }
    return .passageRewrites(chapter: first.chapter, [first] + rest)
  }

  private static func inverseObject(_ undo: ProposalChangeUndo, index: Int) throws(ProposalRevertError) -> OrderedJSONObject {
    guard case .object(let record) = OrderedJSON(undo.inverse) else { throw .apply(index: index, .refused(.malformedInverse)) }
    return record
  }

  private static func inverseType(_ undo: ProposalChangeUndo, index: Int) throws(ProposalRevertError) -> OpType {
    guard let type = undo.inverse["op"]?.stringValue.flatMap({ OpType(exactly: $0) }) else { throw .apply(index: index, .refused(.malformedInverse)) }
    return type
  }

  /// The chapters a draft inverse names, decoded from the stored inverse: its working copy is settled before the guard reads the draft.
  private static func inverseChapters(_ undo: ProposalChangeUndo) -> [Int] {
    guard case .object(let record) = OrderedJSON(undo.inverse), let decoded = try? DraftInverse(record) else { return [] }
    switch decoded {
    case .restore(let write): return [write.chapter]
    case .remove(let chapter): return [chapter]
    }
  }

  private static func settle(chapters: [Int], index: Int, novel: UUID, in transaction: inout WriteTransaction) throws(ProposalRevertError) {
    try performing(index) { () throws(ApplyError) in try DraftHandlers.settleWorkingCopies(chapters: chapters, novel: novel, in: &transaction) }
  }

  // apply-rules.ts:46-51 over what the inverses or the redo wrote (proposal-revert.service.ts:112, :149, :186). After a per-change undo or redo it is
  // practically unreachable: only an inverse or a redo that writes a plan is checked, brief ops are always cards, and an automatic apply refuses those.
  private static func enforce(_ overlay: PlanOverlay, index: Int, novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalRevertError) {
    do throws(DomainError) {
      try ApplyFrame.enforcePlanOps(overlay, novel: novel, in: transaction)
    } catch {
      throw .domain(error)
    }
  }

  static func states(_ refs: [String], novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalRevertError) -> [JSString: ArtifactState] {
    try revertStore { () throws(StoreError) in try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction) }
  }

  // apply-rules.ts:33 (sameContent) failing closed: a ref the change did not record, or that either side cannot read, never matches
  static func mismatches(_ refs: [String], expected: ArtifactStates, actual: [JSString: ArtifactState], index: Int) -> [BaselineMismatch] {
    refs.compactMap { ref in
      let want = expected[ref]
      let found = actual[JSString(ref)]
      guard let want, let found, want.matches(found) else { return BaselineMismatch(ref: ref, expected: want, actual: found, indexes: [index]) }
      return nil
    }
  }

  @discardableResult
  private static func performing<T>(_ index: Int, _ body: () throws(ApplyError) -> T) throws(ProposalRevertError) -> T {
    do throws(ApplyError) {
      return try body()
    } catch {
      throw .apply(index: index, error)
    }
  }

  private static func notebook<T>(_ body: () throws(IdeaRejectionError) -> T) throws(ProposalRevertError) -> T {
    do throws(IdeaRejectionError) {
      return try body()
    } catch {
      throw .notebook(error)
    }
  }
}
