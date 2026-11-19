import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// The read a finalize_review job appends, without running it: the commit needs a ready review of the head (decision 2).
enum FinalizeReviews {
  /// Appends a ready review of the chapter's head under its approval's first job, unless the chapter is final, has no live head, or its head has a read.
  static func ready(novel: UUID, chapter: Int, items: [StoredFinalizeItem] = [], in transaction: inout WriteTransaction) throws {
    let ref = try DraftRecord.ref(novel: novel, chapter: chapter)
    guard try transaction.state(of: try FinalChapterRecord.ref(novel: novel, chapter: chapter)) == nil,
      case .revisioned(let state)? = try transaction.state(of: ref), let head = state.headRevision,
      case .readable(let draft) = try DraftRecord.read(ref, in: transaction), !draft.isRemoved
    else { return }
    let reads = try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).records
    guard !reads.contains(where: { $0.draftRevision == head }) else { return }
    let content = draft.record.content
    let plan = try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction).entry.flatMap { entry -> String? in
      guard !entry.isRemoved, case .revisioned(let state)? = try? transaction.state(of: entry.record.ref) else { return nil }
      return state.headRevision
    }
    let input = FinalizeReviewJobInput(revision: head, body: content.body, plan: plan)
    let job = try FinalizeReviewJobs.key(input, novel: novel, chapter: chapter, run: 1).ref.key
    let record = try FinalizeReviewRecord(
      attempt: try attempt(for: head, chapter: chapter), job: job, novel: novel, chapter: chapter, draftRevision: head, sourceHash: input.sourceHash,
      planHash: plan, isolated: content.isolated, items: items)
    _ = try record.append(in: &transaction)
  }

  @discardableResult
  static func finalize(novel: UUID, chapter: Int? = nil, in transaction: inout WriteTransaction) throws -> Int {
    let target = try chapter ?? lowestApproved(novel: novel, in: transaction)
    if let target { try ready(novel: novel, chapter: target, in: &transaction) }
    return try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &transaction)
  }

  @discardableResult
  static func finalizeDomain(novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws(DomainError) -> Int {
    do {
      try ready(novel: novel, chapter: chapter, in: &transaction)
    } catch {
      throw .store(error as? StoreError ?? .invalidChange(String(describing: error)))
    }
    return try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &transaction)
  }

  private static func lowestApproved(novel: UUID, in transaction: borrowing WriteTransaction) throws -> Int? {
    try ChapterLifecycleEntry.filter(Column("novel") == novel).fetchAll(transaction.database).filter { $0.review == .approved }.map(\.chapter).min()
  }

  /// A version 7 id derived from the revision, so a store reads the same reviews on every run.
  private static func attempt(for revision: String, chapter: Int) throws -> AttemptID {
    var seed: UInt64 = 0xcbf2_9ce4_8422_2325 &+ UInt64(chapter)
    for byte in revision.utf8 { seed = (seed ^ UInt64(byte)) &* 0x100_0000_01b3 }
    var generator = SeededGenerator(seed: seed)
    return try AttemptID(UUID.v7(at: Date(timeIntervalSince1970: 1_800_000_000), using: &generator))
  }
}

enum ReviewItems {
  static func item(
    _ change: ProposedChange, triage: FinalizeTriage = .routine, basis: FinalizeBasis = .observed, position: Int = 0, autoKept: Bool = false,
    flag: FinalizeFlag? = nil, dependents: [String]? = nil
  ) -> StoredFinalizeItem {
    StoredFinalizeItem(
      key: change.itemKey, position: position, category: .known(change.category), triage: .known(triage), basis: .known(basis), subject: subject(of: change),
      claim: "It is written.", proposed: change.json.objectValue ?? [:], flag: flag.map(StoredEnum.known), dependents: dependents,
      autoDecision: autoKept ? .known(.kept) : nil)
  }

  static func items(_ changes: [ProposedChange], autoKept: Bool = false) -> [StoredFinalizeItem] {
    changes.enumerated().map { position, change in item(change, position: position, autoKept: autoKept) }
  }

  private static func subject(of change: ProposedChange) -> String {
    switch change {
    case .entity(let entity): entity.entityKey
    case .appearance(let key): key
    case .characterState(let state): state.entityKey
    case .relationship(let relationship): relationship.entityKey
    case .thread(let thread): thread.threadKey
    case .mystery(let mystery): mystery.mysteryKey
    case .knowledge(let knowledge): knowledge.entityKey
    case .milestone(let milestone): milestone.milestoneKey
    case .summary: "summary"
    }
  }
}

extension ChapterBook {
  func reviewRead(_ chapter: Int, items: [StoredFinalizeItem] = []) async throws {
    let novel = novel
    try await run { try FinalizeReviews.ready(novel: novel, chapter: chapter, items: items, in: &$0) }
  }
}

extension ChapterBook {
  func commit(_ chapter: Int?, by initiator: FinalizeInitiator = .author) -> BookWrite<Int> {
    let novel = novel
    return { try ChapterFinalize.finalize(novel: novel, chapter: chapter, by: initiator, in: &$0) }
  }

  /// A draft written as the generation and import paths write one, isolated or not, with the continuation state given.
  @discardableResult
  func draft(_ chapter: Int, body: String, summary: String?, isolated: Bool, state: [String: JSONValue]?) async throws -> String {
    let novel = novel
    return try await run { transaction in
      let content = DraftContent(
        body: body, summary: summary, source: .known(.handEdited), generator: .known(isolated ? .unrestricted : .standard), isolated: isolated,
        upstream: try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction), state: state)
      let record = try DraftRecord(novel: novel, chapter: chapter, content: content)
      if case .absent = try DraftRecord.read(record.ref, in: transaction) {
        _ = try record.create(in: &transaction)
      } else {
        _ = try DraftRecord.revise(record.ref, content, in: &transaction)
      }
      return try ChapterWrites.head(novel: novel, chapter: chapter, in: transaction) ?? ""
    }
  }

  func refreshJobs() async throws -> [JobRecord] {
    try await FinalizeReviews.refreshJobs(in: store)
  }

  func reads(_ chapter: Int) async throws -> [FinalizeReviewRecord] {
    let novel = novel
    return try await store.read { try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: $0).records }
  }

  func answer(_ chapter: Int, item: String, _ decision: FinalizeDecision, edit: [String: JSONValue]? = nil, reason: String? = nil) async throws {
    try await store.decideFinalizeItem(novel: novel, chapter: chapter, item: item, decision: decision, edit: edit, reason: reason)
  }
}

extension FinalizeReviews {
  static func refreshJobs(in store: VaultStore) async throws -> [JobRecord] {
    try await store.read { transaction in
      try transaction.states(ofKind: JobSchema.jobKind).compactMap { JobRecords.reading($0.state, of: $0.ref).record }
        .filter { $0.request.key.kind == NovelJobKind.canonRefresh.rawValue }
    }
  }
}
