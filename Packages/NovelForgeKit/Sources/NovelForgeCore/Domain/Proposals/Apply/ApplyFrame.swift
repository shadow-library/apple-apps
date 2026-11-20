import Foundation
import ShadowCore
import ShadowStore
import ShadowText

public enum ApplyError: ShadowError, Equatable {
  case invalidSelection
  case rewriteBesideWholeDraft(chapter: Int)
  case noHandler(OpType)
  case notYetAvailable(OpType)
  case unreadable(ref: String)
  /// A handler wrote before it threw: the whole transaction is aborted, never kept with the change recorded as skipped.
  case partialWrite(ref: String)
  /// A handler refused the op before writing; F16 records it as a failed change with the refusal's code.
  case refused(ApplyRefusal)
  case domain(DomainError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .invalidSelection: "RFN_011"
    case .rewriteBesideWholeDraft: "refinement.rewrite_beside_whole_draft"
    case .noHandler: "RFN_004"
    case .notYetAvailable: "refinement.not_yet_available"
    case .unreadable: "refinement.unreadable_record"
    case .partialWrite: "refinement.partial_write"
    case .refused(let refusal): refusal.code
    case .domain(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidSelection: "The selected changes are not changes of this proposal"
    case .rewriteBesideWholeDraft(let chapter): "A change set never rewrites chapter \(chapter) whole beside its passage rewrites"
    case .noHandler(let type): "No handler applies \(type.rawValue)"
    case .notYetAvailable(let type): "Applying \(type.rawValue) is not yet available"
    case .unreadable(let ref): "\(ref) cannot be read on this device, so the change is not applied"
    case .partialWrite(let ref): "A change was refused after it wrote \(ref), so the apply is abandoned"
    case .refused(let refusal): refusal.errorDescription
    case .domain(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: ApplyError, right: ApplyError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}

// apps/novel-forge-server/src/modules/refinement/apply/apply.types.ts:32: restoring a plan's earlier unrestricted mode is not choosing it
enum ApplyIntent: Sendable, Equatable {
  case apply
  case redo
  case undo
}

// apply.types.ts:27; the transaction is passed beside it, and stale marks and applied artifacts are derived or returned per step
struct ApplyContext: Sendable {
  let novel: UUID
  let intent: ApplyIntent
  let now: Date
  /// apply.types.ts:33 (unrestrictedRaise `allowed`): set on an apply or a redo whose caller found unrestricted writing available, never on an undo.
  var unrestrictedRaise = false
}

// apply.types.ts:15; `declined` is never stored (an unselected index has no change record) and `reverted` is written by an undo, not an apply
struct OpResult: Sendable, Equatable {
  let index: Int
  var status: ProposalChangeStatus
  var source: OpSource?
  var error: String?
  var result: OrderedJSONObject?
}

// apply.types.ts:36
public struct BaselineMismatch: Sendable, Equatable {
  let ref: String
  let expected: ArtifactState?
  let actual: ArtifactState?
  public let indexes: [Int]
}

/// What a handler did to the records of one call. The inverse restores the records' content as the handler found it (never a revision or a counter), so
/// apply, undo, redo and undo again land on the same content hash.
struct HandlerOutcome: Sendable, Equatable {
  var result: OrderedJSONObject?
  var inverse: OrderedJSONObject?
  var planEdits: [PlanOverlay.Edit] = []
}

/// A handler reads every record it needs and throws before its first write: a thrown error skips the change. One thrown after a write surfaces as
/// `partialWrite`, on which the whole transaction is aborted.
protocol ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome
}

enum ContentHandlerFile: Sendable, Equatable {
  case story
  case bible
  case plan
  case draft
  case inline
}

/// One handler call of an apply: an op, or a chapter's selected passage rewrites, which land as one revision.
enum ContentCall: Sendable, Equatable {
  case op(ChangeOp)
  case passageRewrites(chapter: Int, [DraftRewritePassage])

  var refs: [String] {
    switch self {
    case .op(let op): changeSetRefs([op])
    case .passageRewrites(let chapter, _): ["draft:\(chapter)"]
    }
  }
}

/// One performed call: `priorState` and `postState` are its refs right before and right after it, so each change guards its own undo and redo.
struct AppliedStep: Sendable, Equatable {
  let result: OrderedJSONObject?
  let inverse: OrderedJSONObject?
  let priorState: [JSString: ArtifactState]
  let postState: [JSString: ArtifactState]
  let planEdits: [PlanOverlay.Edit]
}

enum ApplyFrame {
  // apps/novel-forge-server/src/modules/refinement/apply/content-op-handlers.ts:15
  static func handlerFile(for type: OpType) -> ContentHandlerFile? {
    switch type {
    case .premiseUpdate, .volumeUpsert, .volumeRemove, .factUpsert, .factRemove, .milestoneUpsert, .milestoneRemove, .promiseCreate, .promiseUpdate, .promiseSetPayoff,
      .promiseDrop:
      .story
    case .bibleDocumentUpsert, .bibleDocumentRemove, .entityUpsert, .entityRemove: .bible
    case .briefUpdate, .briefRemove: .plan
    case .draftUpdate, .draftRemove, .draftRewritePassage: .draft
    case .organiseRule: .inline
    case .actionGenerateChapter, .actionAuditBible, .actionEnhancePremise, .actionJudgeDraft, .actionReviseDraft, .actionApproveDraft, .actionApplyContinuity,
      .actionValidate, .actionFinalize, .actionOrganiseNotes, .actionPlanChapter, .actionAdvanceVolume:
      nil
    }
  }

  // content-op-handlers.ts:41-56: the handler sees the operation without its rationale, quote, idea id or started-empty mark, so none is ever stored beside
  // the content it explains; an unreadable record the call writes is refused before any handler runs
  static func perform(_ call: ContentCall, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> AppliedStep {
    try perform(call, context: context, in: &transaction, through: dispatch)
  }

  /// Throws with nothing written, or with `partialWrite` once anything was.
  static func perform(
    _ call: ContentCall, context: ApplyContext, in transaction: inout WriteTransaction,
    through handler: (ContentCall, ApplyContext, inout WriteTransaction) throws(ApplyError) -> HandlerOutcome
  ) throws(ApplyError) -> AppliedStep {
    let refs = call.refs
    let prior = try states(refs, novel: context.novel, in: transaction)
    if let unreadable = refs.first(where: { prior[JSString($0)]?.isUnreadable != false }) { throw .unreadable(ref: unreadable) }
    let written = transaction.changes.count
    let outcome: HandlerOutcome
    let post: [JSString: ArtifactState]
    do throws(ApplyError) {
      outcome = try handler(call, context, &transaction)
      post = try states(refs, novel: context.novel, in: transaction)
    } catch {
      guard transaction.changes.count > written else { throw error }
      let first = transaction.changes[written]
      throw .partialWrite(ref: refs.first ?? "\(first.entity.rawValue)/\(first.key.rawValue)")
    }
    return AppliedStep(result: outcome.result, inverse: outcome.inverse, priorState: prior, postState: post, planEdits: outcome.planEdits)
  }

  // apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:46-51: plans, and the facts, volumes and milestones their reveal rule reads, are
  // checked as the whole change set leaves them; without a written plan nothing is checked (the plan state it would reconcile is derived)
  static func enforcePlanOps(_ overlay: PlanOverlay, novel: UUID, in transaction: borrowing WriteTransaction) throws(DomainError) {
    guard let first = overlay.written.first else { return }
    let world = try transaction.planWorld(novel: novel, chapter: first)
    if let refusal = try world.refusal(of: overlay, novel: novel) { throw refusal }
  }

  // apply-rules.ts:13: the op that releases a brief, plan claim or fact unlock may be listed after the removal
  static func removalsLast<Item>(_ items: [Item], type: (Item) -> OpType) -> [Item] {
    items.filter { type($0) != .volumeRemove && type($0) != .milestoneRemove } + items.filter { type($0) == .volumeRemove }
      + items.filter { type($0) == .milestoneRemove }
  }

  // apply-rules.ts:42; an index without a readable op never runs, so it has no place in the order
  static func applyOrder(_ ops: [ChangeOp?], _ indexes: [Int]) -> [Int] {
    let present = indexes.compactMap { index in ops.indices.contains(index) ? ops[index].map { (index: index, type: $0.type) } : nil }
    return removalsLast(present) { $0.type }.map(\.index)
  }

  private static func dispatch(_ call: ContentCall, _ context: ApplyContext, _ transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    switch call {
    case .passageRewrites(let chapter, let rewrites):
      return try DraftHandlers.rewritePassages(chapter: chapter, rewrites, context: context, in: &transaction)
    case .op(let op):
      switch handlerFile(for: op.type) {
      case .story?: return try StoryHandlers.apply(op.operation, context: context, in: &transaction)
      case .bible?: return try BibleHandlers.apply(op.operation, context: context, in: &transaction)
      case .plan?: return try PlanHandlers.apply(op.operation, context: context, in: &transaction)
      case .draft?: return try DraftHandlers.apply(op.operation, context: context, in: &transaction)
      case .inline?: return HandlerOutcome()
      case nil: throw .noHandler(op.type)
      }
    }
  }

  private static func states(_ refs: [String], novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> [JSString: ArtifactState] {
    do throws(StoreError) {
      return try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction)
    } catch {
      throw .store(error)
    }
  }
}

/// A card's stored operation: the op it revalidates to, or nil with the problems that kept it from validating.
protocol StoredChangeOp {
  var op: ChangeOp? { get }
  var problems: [String] { get }
}

public enum ApplySelection: Sendable, Equatable {
  case whole
  case indexes([Int])
}

struct ApplyStep: Sendable, Equatable {
  enum Disposition: Sendable, Equatable {
    /// The stored op no longer validates: it is recorded as a failed change, never thrown, so history replay is never blocked.
    case skip(problems: [String])
    case run(ContentCall)
    /// A passage rewrite that lands in the revision of its chapter's first selected rewrite.
    case carried(by: Int)
    /// Runs after the content commits, in index order.
    case action(ChangeOp)
  }

  let index: Int
  let disposition: Disposition
}

enum ApplyPlan: Sendable, Equatable {
  /// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts:148-160: no handler runs and no change is recorded.
  case conflicted([BaselineMismatch])
  /// Content steps in the order they run (removals last), then actions in index order, then skipped indexes in index order.
  case ready([ApplyStep])

  // proposal-apply.service.ts:232-238 for the selected indexes only: content `applied`, actions `pending`, a skipped op `failed` with its problems
  func opResults(sources: [OpSource?] = []) -> [OpResult] {
    guard case .ready(let steps) = self else { return [] }
    return steps.sorted { $0.index < $1.index }.map { step in
      let source = sources.indices.contains(step.index) ? sources[step.index] : nil
      switch step.disposition {
      case .skip(let problems): return OpResult(index: step.index, status: .failed, source: source, error: problems.joined(separator: "; "))
      case .run, .carried: return OpResult(index: step.index, status: .applied, source: source)
      case .action: return OpResult(index: step.index, status: .pending, source: source)
      }
    }
  }
}

enum ApplyPlanner {
  private static let unreadableOp = "the stored operation could not be read"

  // proposal-apply.service.ts:241-247
  static func resolve(_ selection: ApplySelection, count: Int) throws(ApplyError) -> [Int] {
    guard case .indexes(let indexes) = selection else { return Array(0..<count) }
    let unique = Array(Set(indexes)).sorted()
    guard !unique.isEmpty, unique.allSatisfy({ $0 >= 0 && $0 < count }) else { throw .invalidSelection }
    return unique
  }

  /// The refs whose current states a plan of `selection` compares with the baseline.
  static func refs<Op: StoredChangeOp>(of ops: [Op], selection: ApplySelection) throws(ApplyError) -> [String] {
    changeSetRefs(try selectedContent(ops, selection).map(\.op))
  }

  static func plan<Op: StoredChangeOp, Transaction: StateReading & ~Copyable>(
    _ ops: [Op], baseline: ArtifactStates, selection: ApplySelection, novel: UUID, in transaction: borrowing Transaction
  ) throws(ApplyError) -> ApplyPlan {
    let refs = try refs(of: ops, selection: selection)
    let current: [JSString: ArtifactState]
    do throws(StoreError) {
      current = try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction)
    } catch {
      throw .store(error)
    }
    return try plan(ops, baseline: baseline, current: current, selection: selection)
  }

  static func plan<Op: StoredChangeOp>(_ ops: [Op], baseline: [JSString: ArtifactState], current: [JSString: ArtifactState], selection: ApplySelection) throws(ApplyError)
    -> ApplyPlan
  {
    try plan(ops, baseline: ArtifactStates(baseline), current: current, selection: selection)
  }

  /// The dry run of an apply: what each selected index would do, or the conflict that stops the whole apply. A current state that was not loaded fails closed.
  static func plan<Op: StoredChangeOp>(_ ops: [Op], baseline: ArtifactStates, current: [JSString: ArtifactState], selection: ApplySelection) throws(ApplyError)
    -> ApplyPlan
  {
    let selected = try resolve(selection, count: ops.count)
    let content = try selectedContent(ops, selection)
    let mismatches = baselineMismatches(content, baseline: baseline, current: ArtifactStates(current))
    if !mismatches.isEmpty { return .conflicted(mismatches) }

    let rewrites = try rewritesByChapter(content)
    var steps = [ApplyStep]()
    for entry in ApplyFrame.removalsLast(content, type: { $0.op.type }) {
      guard case .draftRewritePassage(let rewrite) = entry.op.operation, let group = rewrites[rewrite.chapter], let first = group.first else {
        steps.append(ApplyStep(index: entry.index, disposition: .run(.op(entry.op))))
        continue
      }
      let disposition: ApplyStep.Disposition =
        first.index == entry.index ? .run(.passageRewrites(chapter: rewrite.chapter, group.map(\.rewrite))) : .carried(by: first.index)
      steps.append(ApplyStep(index: entry.index, disposition: disposition))
    }
    for index in selected {
      guard let op = ops[index].op, isActionOp(op) else { continue }
      steps.append(ApplyStep(index: index, disposition: .action(op)))
    }
    for index in selected where ops[index].op == nil {
      let problems = ops[index].problems
      steps.append(ApplyStep(index: index, disposition: .skip(problems: problems.isEmpty ? [unreadableOp] : problems)))
    }
    return .ready(steps)
  }

  private static func selectedContent<Op: StoredChangeOp>(_ ops: [Op], _ selection: ApplySelection) throws(ApplyError) -> [(index: Int, op: ChangeOp)] {
    try resolve(selection, count: ops.count).compactMap { index in
      guard let op = ops[index].op, !isActionOp(op) else { return nil }
      return (index, op)
    }
  }

  // proposal-apply.service.ts:302-321, failing closed: a ref the baseline lacks or cannot decode, or that either side cannot read, is a conflict. A ref only
  // passage rewrites touch finds its passage again, so only its existence is compared
  private static func baselineMismatches(_ content: [(index: Int, op: ChangeOp)], baseline: ArtifactStates, current: ArtifactStates)
    -> [BaselineMismatch]
  {
    let refs = changeSetRefs(content.map(\.op))
    return refs.compactMap { ref in
      let slot = JSString(ref)
      let touching = content.filter { entry in changeSetRefs([entry.op]).contains { JSString($0) == slot } }
      // the rewrite handler finds each passage again by its anchor, so an edit elsewhere in the chapter leaves the card standing
      let passageOnly = touching.allSatisfy { $0.op.type == .draftRewritePassage }
      let expected = baseline[ref]
      let actual = current[ref]
      guard let want = expected, let found = actual else { return BaselineMismatch(ref: ref, expected: expected, actual: actual, indexes: touching.map(\.index)) }
      let holds = passageOnly ? !want.isUnreadable && !found.isUnreadable && want.exists == found.exists : want.matches(found)
      return holds ? nil : BaselineMismatch(ref: ref, expected: want, actual: found, indexes: touching.map(\.index))
    }
  }

  // proposal-apply.service.ts:74-80
  private static func rewritesByChapter(_ content: [(index: Int, op: ChangeOp)]) throws(ApplyError) -> [Int: [(index: Int, rewrite: DraftRewritePassage)]] {
    var byChapter = [Int: [(index: Int, rewrite: DraftRewritePassage)]]()
    for entry in content {
      guard case .draftRewritePassage(let rewrite) = entry.op.operation else { continue }
      byChapter[rewrite.chapter, default: []].append((entry.index, rewrite))
    }
    for entry in content {
      switch entry.op.operation {
      case .draftUpdate(let draft) where byChapter[draft.chapter] != nil: throw .rewriteBesideWholeDraft(chapter: draft.chapter)
      case .draftRemove(let draft) where byChapter[draft.chapter] != nil: throw .rewriteBesideWholeDraft(chapter: draft.chapter)
      default: continue
      }
    }
    return byChapter
  }
}
