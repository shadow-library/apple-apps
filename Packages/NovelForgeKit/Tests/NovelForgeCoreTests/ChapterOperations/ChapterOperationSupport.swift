import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import NovelForgeCore

final class OperationClock: Sendable {
  private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

  var function: @Sendable () -> Date { { self.date.withLock { $0 } } }

  var now: Date { date.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

typealias BookWrite<T> = @Sendable (inout WriteTransaction) throws -> T

/// A novel with the learner `mara`, secrets `heir` (shown from chapter 1) and `tide` (locked until chapter 5), and the milestone `rise`, on one store that
/// reconciles the chapter area.
struct ChapterBook: Sendable {
  let store: VaultStore
  let clock: OperationClock
  let novel = SchemaFixture.novel

  static func make() async throws -> ChapterBook {
    let clock = OperationClock()
    let reconciler = try Projection.reconciler(chapterAreaDerivations)
    let store = try VaultStore.open(.inMemory, registry: Projection.registry, migrations: reconciler.migrations, wallClock: clock.function, reconciler: reconciler)
    let book = ChapterBook(store: store, clock: clock)
    let novel = book.novel
    try await book.run { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.secret(novel: novel, "tide", revealChapter: 5, in: &transaction)
      try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction)
    }
    return book
  }

  @discardableResult
  func run<T: Sendable>(_ body: BookWrite<T>) async throws -> T {
    try await Projection.write(store, body)
  }

  func expect<T: Sendable>(_ expected: DomainError, sourceLocation: SourceLocation = #_sourceLocation, _ body: BookWrite<T>) async {
    do {
      _ = try await store.write(body)
      Issue.record("expected \(expected.code) but the operation succeeded", sourceLocation: sourceLocation)
    } catch {
      guard case .aborted(let cause) = error else {
        Issue.record("expected \(expected.code) but got \(error)", sourceLocation: sourceLocation)
        return
      }
      #expect(cause as? DomainError == expected, "got \(cause)", sourceLocation: sourceLocation)
    }
  }

  func expectRead<T: Sendable>(_ expected: DomainError, sourceLocation: SourceLocation = #_sourceLocation, _ body: @Sendable (ReadTransaction) throws -> T) async {
    do {
      _ = try await store.read(body)
      Issue.record("expected \(expected.code) but the read succeeded", sourceLocation: sourceLocation)
    } catch {
      guard case .aborted(let cause) = error else {
        Issue.record("expected \(expected.code) but got \(error)", sourceLocation: sourceLocation)
        return
      }
      #expect(cause as? DomainError == expected, "got \(cause)", sourceLocation: sourceLocation)
    }
  }

  func expectPlan(_ expected: DomainError, _ chapter: Int, _ edit: PlanEdit, sourceLocation: SourceLocation = #_sourceLocation) async {
    let novel = novel
    await expect(expected, sourceLocation: sourceLocation) { try ChapterPlans.write(novel: novel, chapter: chapter, edit, in: &$0) }
  }

  // MARK: operations as the app calls them

  func plan(_ chapter: Int, _ edit: PlanEdit) async throws {
    let novel = novel
    try await run { try ChapterPlans.write(novel: novel, chapter: chapter, edit, in: &$0) }
  }

  func plan(_ chapter: Int, learns: [KnowledgeReveal] = [], claims: [String]? = nil, ending: Bool? = nil) async throws {
    try await plan(chapter, Self.planEdit(learns: learns, claims: claims, ending: ending))
  }

  static func planEdit(learns: [KnowledgeReveal] = [], claims: [String]? = nil, ending: Bool? = nil, body: String = "The plan.") -> PlanEdit {
    var edit = PlanEdit(body: body)
    edit.knowledge = .set(PlanKnowledge(pov: ["mara"], learns: learns))
    if let claims { edit.claimedMilestones = .set(claims) }
    if let ending { edit.isEnding = .set(ending) }
    return edit
  }

  @discardableResult
  func save(_ chapter: Int, _ body: String, title: String? = nil, summary: String? = nil, base: String?) async throws -> DraftSaveOutcome {
    let (novel, now) = (novel, clock.now)
    return try await run { try ChapterDrafts.save(novel: novel, chapter: chapter, DraftEdit(title: title, body: body, summary: summary), base: base, at: now, in: &$0) }
  }

  /// A committed draft with a summary, so it can be finalized once approved; saved without a base, so it never folds.
  @discardableResult
  func draft(_ chapter: Int, _ body: String = "The tide turns.") async throws -> String {
    guard case .committed(let revision) = try await save(chapter, body, summary: "It turns.", base: nil) else { throw ChapterBookError.notCommitted }
    return revision
  }

  @discardableResult
  func approve(_ chapter: Int, as intent: ApprovalIntent = .standard, id: UUID = UUID()) async throws -> UUID {
    let (novel, requester) = (novel, store.replica)
    guard let head = try await head(chapter) else { throw ChapterBookError.noDraft }
    return try await run { try ChapterApprovals.approve(novel: novel, chapter: chapter, revision: head, as: intent, id: id, requester: requester, in: &$0).id }
  }

  func finalize(_ chapter: Int? = nil) async throws {
    let novel = novel
    try await run { try FinalizeReviews.finalize(novel: novel, chapter: chapter, in: &$0) }
  }

  /// Plans, drafts, approves and finalizes chapters 1 through `last`.
  func finalized(through last: Int) async throws {
    for chapter in 1...last {
      try await plan(chapter)
      try await draft(chapter)
      try await approve(chapter)
      try await finalize(chapter)
    }
  }

  // MARK: reads

  func head(_ chapter: Int) async throws -> String? {
    let novel = novel
    return try await store.read { transaction in
      guard case .revisioned(let state)? = try transaction.state(of: try DraftRecord.ref(novel: novel, chapter: chapter)) else { return nil }
      return state.headRevision
    }
  }

  func draftContent(_ chapter: Int) async throws -> DraftContent? {
    let novel = novel
    return try await store.read { try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: chapter), in: $0).entry?.record.content }
  }

  func planContent(_ chapter: Int) async throws -> ChapterPlanContent? {
    let novel = novel
    return try await store.read { try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: $0).entry?.record.content }
  }

  func final(_ chapter: Int) async throws -> FinalChapterRecord? {
    let novel = novel
    return try await store.read { try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: chapter), in: $0).entry?.record }
  }

  func revisionCount(_ chapter: Int) async throws -> Int {
    let novel = novel
    return try await store.read { transaction in
      guard case .revisioned(let state)? = try transaction.state(of: try DraftRecord.ref(novel: novel, chapter: chapter)) else { return 0 }
      return state.revisions.count
    }
  }

  func history(_ chapter: Int) async throws -> RevisionHistory<DraftContent, DraftMark>? {
    let novel = novel
    return try await store.read { try DraftRecord.history(try DraftRecord.ref(novel: novel, chapter: chapter), in: $0).history }
  }

  /// Executes SQL on the store's own database, as a fault or a lost derived row would leave it; nothing is reconciled.
  func tamper(_ sql: String) async throws {
    _ = try await store.write { transaction in try transaction.database.execute(sql: sql) }
  }

  func approvals(_ chapter: Int) async throws -> [ApprovalRecord] {
    let novel = novel
    return try await store.read { try ApprovalRecord.listing(novel: novel, chapter: chapter, in: $0).records }
  }

  func workingCopy(_ chapter: Int) async throws -> DraftWorkingCopy? {
    let novel = novel
    return try await store.read { try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: $0.database) }
  }

  func lifecycle(_ chapter: Int) async throws -> ChapterLifecycleEntry? {
    try await ChapterTables.lifecycle(novel, in: store)[chapter]
  }

  func view(_ chapter: Int) async throws -> LifecycleView? {
    try await ChapterTables.views(novel, in: store)[chapter]
  }
}

enum ChapterBookError: Error {
  case notCommitted
  case noDraft
}

func reveal(_ entity: String, _ fact: String) -> KnowledgeReveal {
  KnowledgeReveal(entityKey: entity, factKey: fact)
}
