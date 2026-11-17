import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The head of a draft that is not removed, with the revision it names and when that revision was written.
struct DraftHead {
  let record: DraftRecord
  let revision: String
  let created: HLCTimestamp

  var content: DraftContent { record.content }
}

enum DraftPresence {
  case absent
  case removed(DraftRecord)
  case live(DraftHead)
}

/// A plan as approve and finalize bind to it: the head of a plan that is not removed, else none.
struct PlanHead {
  let record: ChapterPlanRecord
  let revision: String
}

enum ChapterRefs {
  static func draft(novel: UUID, chapter: Int) throws(DomainError) -> EntityRef {
    do throws(NovelForgeKeyError) {
      return try DraftRecord.ref(novel: novel, chapter: chapter)
    } catch {
      throw .belowMinimum(field: "chapter", minimum: 1)
    }
  }

  static func plan(novel: UUID, chapter: Int) throws(DomainError) -> EntityRef {
    do throws(NovelForgeKeyError) {
      return try ChapterPlanRecord.ref(novel: novel, chapter: chapter)
    } catch {
      throw .belowMinimum(field: "chapter", minimum: 1)
    }
  }

  static func final(novel: UUID, chapter: Int) throws(DomainError) -> EntityRef {
    do throws(NovelForgeKeyError) {
      return try FinalChapterRecord.ref(novel: novel, chapter: chapter)
    } catch {
      throw .belowMinimum(field: "chapter", minimum: 1)
    }
  }
}

func storeCall<T>(_ body: () throws(StoreError) -> T) throws(DomainError) -> T {
  do throws(StoreError) {
    return try body()
  } catch {
    throw .store(error)
  }
}

extension WriteTransaction {
  func draft(novel: UUID, chapter: Int) throws(DomainError) -> DraftPresence {
    let ref = try ChapterRefs.draft(novel: novel, chapter: chapter)
    let state = try storeCall { () throws(StoreError) in try self.state(of: ref, scope: .vault) }
    switch DraftRecord.reading(state, of: ref) {
    case .absent: return .absent
    case .unreadable: throw .unreadable(ref)
    case .readable(let entry):
      guard !entry.isRemoved else { return .removed(entry.record) }
      guard case .revisioned(let revisioned)? = state, let head = revisioned.headRevision, let item = revisioned.revisions[ExactString(head)] else {
        throw .unreadable(ref)
      }
      return .live(DraftHead(record: entry.record, revision: head, created: item.created))
    }
  }

  func liveDraft(novel: UUID, chapter: Int) throws(DomainError) -> DraftHead {
    guard case .live(let head) = try draft(novel: novel, chapter: chapter) else { throw .draftNotFound(chapter) }
    return head
  }

  /// A plan whose head this version cannot read refuses, so nothing is bound to terms it cannot compute.
  func planHead(novel: UUID, chapter: Int) throws(DomainError) -> PlanHead? {
    let ref = try ChapterRefs.plan(novel: novel, chapter: chapter)
    let state = try storeCall { () throws(StoreError) in try self.state(of: ref, scope: .vault) }
    switch ChapterPlanRecord.reading(state, of: ref) {
    case .absent: return nil
    case .unreadable: throw .unreadable(ref)
    case .readable(let entry):
      guard !entry.isRemoved else { return nil }
      guard case .revisioned(let revisioned)? = state, let head = revisioned.headRevision else { throw .unreadable(ref) }
      return PlanHead(record: entry.record, revision: head)
    }
  }

  /// Whether the chapter's canon exists, readable or not.
  func isFinal(novel: UUID, chapter: Int) throws(DomainError) -> Bool {
    let ref = try ChapterRefs.final(novel: novel, chapter: chapter)
    let state = try storeCall { () throws(StoreError) in try self.state(of: ref, scope: .vault) }
    return FinalChapterRecord.reading(state, of: ref) != .absent
  }

  /// The chapter as the lifecycle reconciled it at the transaction's start; refuses while it is faulted or not about the head the transaction reads.
  func lifecycle(novel: UUID, chapter: Int, head: String) throws(DomainError) -> ChapterLifecycleEntry {
    guard try !lifecycleFaulted(novel: novel), let entry = try storeCall({ () throws(StoreError) in try ChapterLifecycleEntry.read(novel: novel, chapter: chapter, in: database) }),
      entry.draft == head
    else { throw .lifecycleUnavailable(chapter) }
    return entry
  }

  /// Whether the lifecycle or the reveal verdicts of the novel are faulted, so their rows may not be the novel's state.
  func lifecycleFaulted(novel: UUID) throws(DomainError) -> Bool {
    try faulted(novel: novel, keyedByNovel: [ChapterLifecycleEntry.databaseTableName, PlanRevealEntry.databaseTableName])
  }

  /// Whether one of the derivations, keyed by novel, is faulted for the whole frame or for the novel.
  func faulted(novel: UUID, keyedByNovel tables: [String]) throws(DomainError) -> Bool {
    try sql { database in
      guard try database.tableExists(ProjectionFaults.table) else { return false }
      let placeholders = tables.map { _ in "?" }.joined(separator: ", ")
      return try Bool.fetchOne(
        database, sql: "SELECT EXISTS (SELECT 1 FROM \(ProjectionFaults.table) WHERE derivation IN (\(placeholders)) AND key IN (?, ?))",
        arguments: StatementArguments(tables + [ProjectionFaults.wholeDerivation, ProjectionFaults.key(novel)])) ?? false
    }
  }

  /// The keys of one derivation's faults on single keys (whole-derivation faults are not among them).
  func faultKeys(of table: String) throws(DomainError) -> [String] {
    try sql { database in
      guard try database.tableExists(ProjectionFaults.table) else { return [] }
      return try String.fetchAll(
        database, sql: "SELECT key FROM \(ProjectionFaults.table) WHERE derivation = ? AND key <> ?", arguments: [table, ProjectionFaults.wholeDerivation])
    }
  }

  func lifecycleEntries(novel: UUID) throws(DomainError) -> [ChapterLifecycleEntry] {
    try fetch(ChapterLifecycleDerivation.request(for: novel))
  }

  func revealVerdict(novel: UUID, chapter: Int) throws(DomainError) -> PlanRevealEntry? {
    try fetch(PlanRevealDerivation.request(for: novel).filter(Column("chapter") == chapter)).first
  }

  func finalChapters(novel: UUID) throws(DomainError) -> [Int] {
    try fetch(FinalChapterEntry.filter(Column("novel") == novel)).map(\.chapter)
  }

  func fetch<Output: FetchableRecord>(_ request: QueryInterfaceRequest<Output>) throws(DomainError) -> [Output] {
    try sql { database in try request.fetchAll(database) }
  }

  func sql<T>(_ body: (Database) throws -> T) throws(DomainError) -> T {
    do {
      return try body(database)
    } catch let error as StoreError {
      throw .store(error)
    } catch {
      throw .store(StoreError(projecting: error))
    }
  }

}
