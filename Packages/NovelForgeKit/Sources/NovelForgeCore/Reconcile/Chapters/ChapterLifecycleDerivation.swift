import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// One chapter of a novel that has a canon, a draft that is not removed, or a plan that is not removed. `resting`, `canonDigest` and `taught` are what a later
/// chapter's draft records about this one (`taught` only for an unfinalized chapter; a final one teaches its canon's learns); `differences` is the digest an
/// `as_written` approval of the head records to accept them.
public struct ChapterLifecycleEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_chapter_lifecycle"

  public let novel: UUID
  public let chapter: Int
  public let isFinal: Bool
  public let draft: String?
  public let resting: String?
  public let canonDigest: String?
  public let taught: String?
  public let review: DraftReviewState?
  public let approval: UUID?
  public let approvalKind: ApprovalKind?
  public let stale: StaleCause?
  public let planStale: StaleCause?
  public let differences: String?

  init(novel: UUID, _ state: ChapterState) {
    self.init(
      novel: novel, chapter: state.chapter, isFinal: state.isFinal, draft: state.draft, resting: state.resting, canonDigest: state.canonDigest, taught: state.taught,
      review: state.review, approval: state.approval?.id, approvalKind: state.approval?.approvalKind, stale: state.stale, planStale: state.planStale,
      differences: state.differences)
  }

  init(
    novel: UUID, chapter: Int, isFinal: Bool, draft: String?, resting: String?, canonDigest: String?, taught: String?, review: DraftReviewState?, approval: UUID?,
    approvalKind: ApprovalKind?, stale: StaleCause?, planStale: StaleCause?, differences: String?
  ) {
    self.novel = novel
    self.chapter = chapter
    self.isFinal = isFinal
    self.draft = draft
    self.resting = resting
    self.canonDigest = canonDigest
    self.taught = taught
    self.review = review
    self.approval = approval
    self.approvalKind = approvalKind
    self.stale = stale
    self.planStale = planStale
    self.differences = differences
  }

  public init(row: Row) throws {
    let text = { (column: String) throws -> String? in try row.decode(String?.self, forColumn: column) }
    let cause = { (prefix: String) throws -> StaleCause? in
      guard let code = try text(prefix) else { return nil }
      guard let cause = StaleCause(code: code, chapter: try row.decode(Int?.self, forColumn: "\(prefix)_chapter"), detail: try text("\(prefix)_detail")) else {
        throw StoreError.corruptStore("a chapter lifecycle entry holds an unknown stale cause")
      }
      return cause
    }
    let review = try text("review").map { stored in
      guard let review = DraftReviewState(rawValue: stored) else { throw StoreError.corruptStore("a chapter lifecycle entry holds an unknown review status") }
      return review
    }
    let approvalKind = try text("approval_kind").map { stored in
      guard let kind = ApprovalKind(rawValue: stored) else { throw StoreError.corruptStore("a chapter lifecycle entry holds an unknown approval kind") }
      return kind
    }
    self.init(
      novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"), isFinal: try row.decode(Bool.self, forColumn: "final"),
      draft: try text("draft"), resting: try text("resting"), canonDigest: try text("canon"), taught: try text("taught"), review: review,
      approval: try text("approval").flatMap(ApprovalColumn.decode), approvalKind: approvalKind, stale: try cause("stale"), planStale: try cause("plan_stale"),
      differences: try text("differences"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["novel"] = novel
    container["chapter"] = chapter
    container["final"] = isFinal
    container["draft"] = draft
    container["resting"] = resting
    container["canon"] = canonDigest
    container["taught"] = taught
    container["review"] = review?.rawValue
    container["approval"] = approval.map(ApprovalColumn.encode)
    container["approval_kind"] = approvalKind?.rawValue
    for (prefix, cause) in [("stale", stale), ("plan_stale", planStale)] {
      container[prefix] = cause?.code
      container["\(prefix)_chapter"] = cause?.chapter
      container["\(prefix)_detail"] = cause?.detail
    }
    container["differences"] = differences
  }
}

// ChapterFingerprint's rules over one novel: final chapters from the canon layer, drafts and approvals from theirs, plan terms and reveal verdicts from D20's plan world.
public struct ChapterLifecycleDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_chapter_lifecycle (
      novel BLOB NOT NULL, chapter INTEGER NOT NULL, final INTEGER NOT NULL, draft TEXT, resting TEXT, canon TEXT, taught TEXT, review TEXT, approval TEXT,
      approval_kind TEXT, stale TEXT, stale_chapter INTEGER, stale_detail TEXT, plan_stale TEXT, plan_stale_chapter INTEGER, plan_stale_detail TEXT, differences TEXT,
      PRIMARY KEY (novel, chapter)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [
      .outputs(of: FinalChapterDerivation.self) { [$0.novel] },
      .outputs(of: ChapterDraftDerivation.self) { [$0.novel] },
      .outputs(of: ChapterApprovalDerivation.self) { [$0.novel] },
      .outputs(of: PlanWorldDerivation.self) { [$0.novel] },
      .outputs(of: PlanRevealDerivation.self) { [$0.novel] },
    ]
  }

  public static func key(of output: ChapterLifecycleEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<ChapterLifecycleEntry> {
    ChapterLifecycleEntry.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    let finals = try context.fetchAll(FinalChapterEntry.all()).map(\.novel)
    let drafts = try context.fetchAll(ChapterDraftEntry.all()).map(\.novel)
    let worlds = try context.fetchAll(PlanWorldEntry.all()).map(\.novel)
    return Set(finals + drafts + worlds)
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [ChapterLifecycleEntry] {
    ChapterLifecycle.states(try Self.inputs(of: novel, in: context)).map { ChapterLifecycleEntry(novel: novel, $0) }
  }

  static func inputs(of novel: UUID, in context: DerivationContext) throws(StoreError) -> LifecycleInputs {
    var inputs = LifecycleInputs()
    for final in try context.fetchAll(FinalChapterEntry.filter(Column("novel") == novel)) { inputs.finals[final.chapter] = final }
    var recorded = Set<Int>()
    for draft in try context.fetchAll(ChapterDraftEntry.filter(Column("novel") == novel)) {
      inputs.drafts[draft.chapter] = draft
      guard inputs.finals[draft.chapter] == nil, let upstream = draft.recordedUpstream else { continue }
      inputs.upstreams[draft.chapter] = upstream
      for case .draft(let chapter, _, .some(_)) in upstream.entries { recorded.insert(chapter) }
    }
    if let world = try NovelPlanWorld.stored(for: novel, in: context) {
      let unreadable = Set(world.unreadablePlans)
      for chapter in world.plans where inputs.finals[chapter] == nil { inputs.plans[chapter] = unreadable.contains(chapter) ? .unreadable : .empty }
      for chapter in world.chapters {
        let pairs = chapter.learns.map { ($0.entity, $0.fact) }
        switch chapter.basis {
        case .canon:
          guard recorded.contains(chapter.chapter) else { continue }
          inputs.canonLearns[chapter.chapter] = ChapterFingerprint.learns(pov: chapter.pov, learns: pairs)
        case .plan:
          guard inputs.finals[chapter.chapter] == nil else { continue }
          let learns = ChapterFingerprint.learns(pov: chapter.pov, learns: pairs)
          inputs.plans[chapter.chapter] = .terms(learns: learns, terms: ChapterFingerprint.terms(pov: chapter.pov, learns: pairs, claims: chapter.claims))
        }
      }
    }
    for verdict in try context.fetchAll(PlanRevealDerivation.request(for: novel)) where verdict.status == .violated {
      guard let reason = verdict.reason else { continue }
      inputs.reveals[verdict.chapter] = reason
    }
    let open = Set(inputs.drafts.keys).subtracting(inputs.finals.keys)
    if let first = open.min() {
      let approvals = try context.fetchAll(ChapterApprovalEntry.filter(Column("novel") == novel && Column("chapter") >= first))
      for approval in approvals.sorted(by: ChapterApprovalEntry.precedes) where open.contains(approval.chapter) {
        inputs.approvals[approval.chapter, default: []].append(approval)
      }
    }
    return inputs
  }
}

extension ChapterLifecycleEntry {
  /// The chapter as reconciled up to the transaction's start; a write that changes an earlier chapter first reads it before that change is reconciled.
  public static func read(novel: UUID, chapter: Int, in database: Database) throws(StoreError) -> ChapterLifecycleEntry? {
    try fetching(database) { database in try ChapterLifecycleDerivation.request(for: novel).filter(Column("chapter") == chapter).fetchOne(database) }
  }

  fileprivate static func fetching<T>(_ database: Database, _ body: (Database) throws -> T) throws(StoreError) -> T {
    do {
      return try body(database)
    } catch {
      throw StoreError(projecting: error)
    }
  }
}

extension DraftUpstream {
  /// What a draft revision of `chapter` written now rests on (`ChapterFingerprint` rule 2). Finals and draft heads are read from the transaction, so earlier writes
  /// in it count; what an ancestor teaches comes from the lifecycle as reconciled at the transaction's start, and only while that ancestor's head is unchanged.
  /// While the lifecycle of the novel is faulted it records no entries, which reads as `unrecorded` rather than as ancestors that teach nothing.
  public static func current(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(StoreError) -> DraftUpstream {
    guard chapter > 1, try !lifecycleFaulted(novel: novel, in: transaction.database) else { return DraftUpstream(entries: []) }
    let earlier = try ChapterLifecycleEntry.fetching(transaction.database) { database in
      try ChapterLifecycleDerivation.request(for: novel).filter(Column("chapter") < chapter).fetchAll(database)
    }
    let reconciled = Dictionary(earlier.map { ($0.chapter, $0) }) { first, _ in first }
    var entries = [Entry]()
    for ancestor in stride(from: chapter - 1, through: 1, by: -1) {
      if let canon = try canon(novel: novel, chapter: ancestor, in: transaction) {
        entries.append(.canon(chapter: ancestor, digest: canon))
        break
      }
      let head = try liveHead(novel: novel, chapter: ancestor, in: transaction)
      let taught = reconciled[ancestor].flatMap { $0.draft != nil && $0.draft == head ? $0.taught : nil }
      entries.append(.draft(chapter: ancestor, revision: head, taught: taught))
    }
    return DraftUpstream(entries: entries.reversed())
  }

  private static func lifecycleFaulted(novel: UUID, in database: Database) throws(StoreError) -> Bool {
    try ChapterLifecycleEntry.fetching(database) { database in
      guard try database.tableExists(ProjectionFaults.table) else { return false }
      return try Bool.fetchOne(
        database, sql: "SELECT EXISTS (SELECT 1 FROM \(ProjectionFaults.table) WHERE derivation = ? AND key IN (?, ?))",
        arguments: [ChapterLifecycleEntry.databaseTableName, ProjectionFaults.wholeDerivation, String(reflecting: novel)]) ?? false
    }
  }

  /// The digest of the chapter's stored canon; nil when it has none, and the digest of nothing when its canon member cannot be read.
  private static func canon(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(StoreError) -> String?? {
    guard let ref = try? FinalChapterRecord.ref(novel: novel, chapter: chapter), let state = try transaction.state(of: ref, scope: .vault) else { return nil }
    guard !FinalChapterRecord.isPending(state), case .revisioned(let revisioned) = state else { return nil }
    return .some(revisioned[field: FinalChapterField.canon.rawValue].map { FinalChapterRecord.digest($0.value) })
  }

  private static func liveHead(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(StoreError) -> String? {
    guard let ref = try? DraftRecord.ref(novel: novel, chapter: chapter), let state = try transaction.state(of: ref, scope: .vault) else { return nil }
    guard case .revisioned(let revisioned) = state else { return nil }
    switch DraftRecord.reading(state, of: ref) {
    case .absent: return nil
    case .readable(let entry): return entry.isRemoved ? nil : revisioned.headRevision
    case .unreadable: return revisioned.headRevision
    }
  }
}
