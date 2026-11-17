import Foundation
import ShadowCore
import ShadowStore

extension ProposalOp: StoredChangeOp {}

typealias ContentPerformer = (ContentCall, ApplyContext, inout WriteTransaction) throws(ApplyError) -> AppliedStep

// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts. Not ported: the audit and organise selections and the organise decision (:122-123,
// :202), feedback rows (:204-216), the cost tier of actions (:292-300) and the caller-transaction mode (:43, :129).
enum ProposalApply {
  // proposal-apply.service.ts:65-71: finalize locks prose and the rest are never applied by a blanket apply, so the author selects the op's own index
  static let oneWayDoors: Set<OpType> = [.actionFinalize, .actionApproveDraft, .actionApplyContinuity, .actionGenerateChapter, .actionAdvanceVolume]

  /// proposal-apply.service.ts:109-219: the content of the selected indexes, its change records and the decision, in this one transaction. A conflict with
  /// the card's baseline records nothing; a stored op that no longer validates is recorded as a failed change while the rest apply; any handler error, a
  /// broken plan rule or a store failure aborts everything and leaves the card pending. Selected actions are recorded `pending` and run after the commit,
  /// each in a transaction of its own (`runAction`), because their guards read the lifecycle as reconciled when a transaction starts. On a conflict the
  /// working copies the apply settled stay committed, as leaving the editor would commit them; `conflicted` itself is derived, never stored.
  static func apply(
    proposal id: UUID, selection: ApplySelection, context: ProposalApplyContext, in transaction: inout WriteTransaction,
    performing perform: ContentPerformer = { call, context, transaction throws(ApplyError) in try ApplyFrame.perform(call, context: context, in: &transaction) }
  ) throws(ProposalApplyError) -> ProposalApplyOutcome {
    let proposal = try pending(id, novel: context.novel, in: transaction)
    let ops = proposal.card.changeSet
    let selected = try applying { () throws(ApplyError) in try ApplyPlanner.resolve(selection, count: ops.count) }
    let chosen = selected.compactMap { index in ops[index].op.map { (index: index, op: $0) } }
    try requireAllowed(chosen.map(\.op), selection: selection, context: context, count: ops.count)

    try applying { () throws(ApplyError) in
      try DraftHandlers.settleWorkingCopies(chapters: DraftHandlers.draftChapters(of: chosen.map(\.op)), novel: context.novel, in: &transaction)
    }
    let plan = try applying { () throws(ApplyError) in
      try ApplyPlanner.plan(ops, baseline: proposal.card.baseline, selection: selection, novel: context.novel, in: transaction)
    }
    let steps: [ApplyStep]
    switch plan {
    case .conflicted(let mismatches): return .conflicted(mismatches)
    case .ready(let ready): steps = ready
    }
    let content = chosen.map(\.op).filter { !isActionOp($0) }
    if proposal.card.kind == .known(.chapterPlan) { try requirePlanCardCurrent(content, novel: context.novel, in: transaction) }

    let raise = context.unrestrictedAvailable && chosen.contains { raisesToUnrestricted($0.op) }
    let applyContext = ApplyContext(novel: context.novel, intent: .apply, now: context.now, unrestrictedRaise: raise)
    let performed = try performSteps(steps, context: applyContext, in: &transaction, performing: perform)
    try domain { () throws(DomainError) in try ApplyFrame.enforcePlanOps(performed.overlay, novel: context.novel, in: transaction) }

    let postState = try stored { () throws(StoreError) in
      ArtifactStates(try ArtifactStateLoader.states(refs: changeSetRefs(content), novel: context.novel, in: transaction))
    }
    let outcomes = steps.map(\.index).sorted().map { index in
      ProposalChangeOutcome(
        index: index, status: performed.status(of: index), source: context.sources?[index], failure: performed.failures[index])
    }
    let changes = try outcomes.map { outcome throws(ProposalApplyError) in try changeRecord(outcome, proposal: proposal, steps: performed.applied) }
    let recording = try stored { () throws(StoreError) in
      try ProposalRecord.recordApply(
        proposal.ref, changes: changes, postState: postState, sources: context.sources?.map(StoredEnum.known), automatic: context.automatic, in: &transaction)
    }
    if case .notPending(let decision) = recording { throw .notPending(decision) }
    return .applied(outcomes)
  }

  // proposal-apply.service.ts:118-119 (RFN_001, RFN_002)
  static func pending(_ id: UUID, novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalApplyError) -> ProposalRecord {
    let proposal = try readable(id, novel: novel, in: transaction)
    guard proposal.decision == .known(.pending) else { throw .notPending(proposal.decision) }
    return proposal
  }

  static func readable<Transaction: StateReading & ~Copyable>(_ id: UUID, novel: UUID, in transaction: borrowing Transaction) throws(ProposalApplyError)
    -> ProposalRecord
  {
    switch try stored({ () throws(StoreError) in try ProposalRecord.read(id: id, in: transaction) }) {
    case .absent: throw .notFound(id)
    case .unreadable: throw .unreadable(id)
    case .readable(let entry):
      guard entry.record.novel == novel else { throw .notFound(id) }
      return entry.record
    }
  }

  // proposal-apply.service.ts:129-139: an automatic apply carries content the write policy let through, a blanket apply refuses the one-way doors, and an
  // action this version cannot run refuses the apply before anything is written
  private static func requireAllowed(_ ops: [ChangeOp], selection: ApplySelection, context: ProposalApplyContext, count: Int) throws(ProposalApplyError) {
    let actions = ops.filter(isActionOp)
    if context.automatic, !actions.isEmpty { throw .automaticAction }
    if context.automatic, let card = ops.first(where: { $0.type.alwaysCardRule != nil }) { throw .automaticAlwaysCard(card.type) }
    if selection == .whole, let door = actions.first(where: { oneWayDoors.contains($0.type) }) { throw .oneWayDoor(door.type) }
    if let unavailable = actions.first(where: { ProposalActionRegistry.executor(for: $0.type) == nil }) { throw .apply(.notYetAvailable(unavailable.type)) }
    // proposal-apply.service.ts:162
    if let sources = context.sources, sources.count != count { throw .sourcesMismatch(expected: count, found: sources.count) }
  }

  // proposal-apply.service.ts:83-89 (PLN_008): a plan pass plans only the next chapter, so its card goes out of date once a draft moves the story past it
  private static func requirePlanCardCurrent(_ ops: [ChangeOp], novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalApplyError) {
    let planned = ops.compactMap { op -> Int? in
      guard case .briefUpdate(let update) = op.operation else { return nil }
      return update.chapter
    }
    guard !planned.isEmpty else { return }
    let next = try domain { () throws(DomainError) in try ChapterDrafts.nextWritableChapter(novel: novel, in: transaction) }
    if let stale = planned.first(where: { $0 != next }) { throw .planCardStale(chapter: stale, next: next) }
  }

  // apply/unrestricted-raise.ts:10
  static func raisesToUnrestricted(_ op: ChangeOp) -> Bool {
    guard case .briefUpdate(let update) = op.operation else { return false }
    return update.contentMode == .set(.unrestricted)
  }

  private struct Performed {
    var applied = [Int: AppliedStep]()
    var failures = [Int: ProposalChangeFailure]()
    var actions = Set<Int>()
    var overlay = PlanOverlay()

    func status(of index: Int) -> ProposalChangeStatus {
      if actions.contains(index) { return .pending }
      return failures[index] == nil ? .applied : .failed
    }
  }

  // proposal-apply.service.ts:173-181: removals last, a chapter's selected rewrites as one call whose undo and states are stored under its first index; any
  // handler error rolls the whole apply back (:106) and names the indexes its call covers, so the author can leave them out
  private static func performSteps(_ steps: [ApplyStep], context: ApplyContext, in transaction: inout WriteTransaction, performing perform: ContentPerformer)
    throws(ProposalApplyError) -> Performed
  {
    var performed = Performed()
    for step in steps {
      switch step.disposition {
      case .skip(let problems): performed.failures[step.index] = ProposalChangeFailure(code: "RFN_004", message: problems.joined(separator: "; "))
      case .carried: continue
      case .action: performed.actions.insert(step.index)
      case .run(let call):
        do throws(ApplyError) {
          let applied = try perform(call, context, &transaction)
          performed.applied[step.index] = applied
          performed.overlay.append(applied.planEdits)
        } catch {
          switch error {
          case .partialWrite, .store: throw .apply(error)
          default: throw .changeRefused(indexes: [step.index] + carried(by: step.index, in: steps), error)
          }
        }
      }
    }
    return performed
  }

  private static func carried(by first: Int, in steps: [ApplyStep]) -> [Int] {
    steps.compactMap { step in
      guard case .carried(let by) = step.disposition, by == first else { return nil }
      return step.index
    }
  }

  private static func changeRecord(_ outcome: ProposalChangeOutcome, proposal: ProposalRecord, steps: [Int: AppliedStep]) throws(ProposalApplyError)
    -> ProposalChangeRecord
  {
    let step = outcome.status == .applied ? steps[outcome.index] : nil
    let undo: ProposalChangeUndo?
    let result: ProposalChangeResult?
    do throws(ProposalRecordError) {
      undo = try step.flatMap { step throws(ProposalRecordError) in
        try step.inverse.map { inverse throws(ProposalRecordError) in
          try ProposalChangeUndo(inverse: inverse, priorState: ArtifactStates(step.priorState), postState: ArtifactStates(step.postState))
        }
      }
      if let failure = outcome.failure {
        result = failure.stored
      } else {
        result = try step?.result.map { result throws(ProposalRecordError) in
          guard let stored = OrderedJSON.object(result).storable else { throw .unstorableOperation(index: outcome.index) }
          return ProposalChangeResult(result: stored)
        }
      }
    } catch {
      throw .unstorable(error)
    }
    do throws(NovelForgeKeyError) {
      return try ProposalChangeRecord(novel: proposal.novel, proposal: proposal.id, index: outcome.index, status: outcome.status, undo: undo, result: result)
    } catch {
      throw .store(.invalidChange(error.errorDescription ?? error.code))
    }
  }

  static func applying<T>(_ body: () throws(ApplyError) -> T) throws(ProposalApplyError) -> T {
    do throws(ApplyError) {
      return try body()
    } catch {
      throw .apply(error)
    }
  }

  static func domain<T>(_ body: () throws(DomainError) -> T) throws(ProposalApplyError) -> T {
    do throws(DomainError) {
      return try body()
    } catch {
      throw .domain(error)
    }
  }

  static func stored<T>(_ body: () throws(StoreError) -> T) throws(ProposalApplyError) -> T {
    do throws(StoreError) {
      return try body()
    } catch {
      throw .store(error)
    }
  }
}
