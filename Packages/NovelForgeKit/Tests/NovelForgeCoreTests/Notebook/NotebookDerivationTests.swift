import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias Fixture = NotebookFixture

private struct Row: Equatable, Comparable {
  let entry: UUID
  let state: NotebookEntryState

  static func < (left: Row, right: Row) -> Bool { left.entry.uuidString < right.entry.uuidString }
}

private func rows(_ novel: UUID = Fixture.novel, in store: VaultStore) async throws -> [Row] {
  let fetched = try await Projection.fetch(NotebookEntryStateDerivation.request(for: novel), in: store)
  for row in fetched { #expect(row.status == row.state.status) }
  return fetched.map { Row(entry: $0.entry, state: $0.state) }.sorted()
}

private func states(_ novel: UUID = Fixture.novel, in store: VaultStore) async throws -> [UUID: NotebookEntryState] {
  Dictionary(uniqueKeysWithValues: try await rows(novel, in: store).map { ($0.entry, $0.state) })
}

private func derivedStore() throws -> (VaultStore, NovelForgeReconciler) {
  let reconciler = try Projection.reconciler()
  return (try Projection.store(reconciler), reconciler)
}

private func append<R: AppendedRecord>(_ record: R, in store: VaultStore) async throws {
  _ = try await Projection.write(store) { transaction in try record.append(in: &transaction) }
}

private func record(_ entry: NewNotebookEntry, novel: UUID = Fixture.novel, in store: VaultStore) async throws -> NotebookEntryRecord {
  try await Projection.write(store) { transaction in try Notebook.record(entry, novel: novel, in: &transaction) }
}

@Suite("Notebook derivation", TestTimeLimit.standard)
struct NotebookDerivationTests {
  @Test func shouldKeepAnEntryActiveUntilItIsSupersededOrWithdrawn() async throws {
    let (store, _) = try derivedStore()
    try await Projection.createNovel(Fixture.novel, in: store)
    let kept = try await record(Fixture.decision("kept"), in: store)
    let old = try await record(Fixture.decision("old"), in: store)
    let dropped = try await record(Fixture.decision("dropped"), in: store)
    #expect(try await states(in: store) == [kept.id: .active, old.id: .active, dropped.id: .active])

    let next = try await Projection.write(store) { transaction in
      try Notebook.supersedeByAuthor(old.id, rewrite: NotebookRewrite(statement: "New"), novel: Fixture.novel, in: &transaction)
    }
    let withdrawal = try await Projection.write(store) { transaction in try Notebook.withdraw(dropped.id, reason: "Dropped", novel: Fixture.novel, in: &transaction) }
    #expect(
      try await states(in: store) == [
        kept.id: .active, old.id: NotebookEntryState(successor: next.id, withdrawal: nil), next.id: .active,
        dropped.id: NotebookEntryState(successor: nil, withdrawal: withdrawal.id),
      ])
  }

  @Test func shouldAgreeWithTheLedgerTheOperationsRead() async throws {
    let (store, _) = try derivedStore()
    try await Projection.createNovel(Fixture.novel, in: store)
    let first = try await record(Fixture.decision("a"), in: store)
    _ = try await record(Fixture.decision("b"), in: store)
    _ = try await Projection.write(store) { transaction in
      try Notebook.supersedeByAuthor(first.id, rewrite: NotebookRewrite(statement: "New"), novel: Fixture.novel, in: &transaction)
    }
    let ledger = try await Fixture.ledger(store)
    #expect(Dictionary(uniqueKeysWithValues: ledger.entries.map { ($0.id, $0.state) }) == (try await states(in: store)))
  }

  @Test func shouldKeepEachNovelsEntriesApart() async throws {
    let (store, _) = try derivedStore()
    try await Projection.createNovel(Fixture.novel, in: store)
    try await Projection.createNovel(Fixture.other, in: store)
    let mine = try await record(Fixture.decision(), in: store)
    let theirs = try await record(Fixture.decision(), novel: Fixture.other, in: store)
    #expect(try await states(in: store) == [mine.id: .active])
    #expect(try await states(Fixture.other, in: store) == [theirs.id: .active])
  }

  @Test func shouldIgnoreAWithdrawalOrSupersedeThatNamesAnEntryOfAnotherNovelOrNoEntry() async throws {
    let (store, _) = try derivedStore()
    try await Projection.createNovel(Fixture.novel, in: store)
    try await Projection.createNovel(Fixture.other, in: store)
    let mine = try await record(Fixture.decision(), in: store)
    let theirs = try await record(Fixture.decision(), novel: Fixture.other, in: store)
    try await append(NotebookWithdrawalRecord(novel: Fixture.novel, entry: theirs.id, reason: "wrong novel"), in: store)
    try await append(NotebookWithdrawalRecord(novel: Fixture.novel, entry: UUID(), reason: "no entry"), in: store)
    try await append(NotebookWithdrawalRecord(novel: Fixture.other, entry: mine.id, reason: "wrong novel"), in: store)
    try await append(NotebookEntryRecord(novel: Fixture.novel, entryKind: .known(.decision), topic: "x", statement: "s", supersedes: theirs.id), in: store)
    try await append(NotebookEntryRecord(novel: Fixture.novel, entryKind: .known(.decision), topic: "y", statement: "s", supersedes: UUID()), in: store)
    let mineAfter = try await states(in: store)
    #expect(mineAfter[mine.id] == .active)
    #expect(mineAfter.count == 3)
    #expect(mineAfter.values.allSatisfy { $0 == .active })
    #expect(try await states(Fixture.other, in: store) == [theirs.id: .active])
  }
}

extension NotebookDerivationTests {
  @Test func shouldApplyAWithdrawalThatArrivesBeforeItsEntry() async throws {
    let (store, _) = try derivedStore()
    let id = UUID()
    let withdrawal = NotebookWithdrawalRecord(novel: Fixture.novel, entry: id, reason: "early")
    try await append(withdrawal, in: store)
    #expect(try await rows(in: store).isEmpty)
    try await append(NotebookEntryRecord(id: id, novel: Fixture.novel, entryKind: .known(.decision), topic: "t", statement: "s"), in: store)
    #expect(try await states(in: store) == [id: NotebookEntryState(successor: nil, withdrawal: withdrawal.id)])
  }

  @Test func shouldSupersedeAnEntryWhoseSuccessorArrivesBeforeIt() async throws {
    let (store, _) = try derivedStore()
    let id = UUID()
    let next = NotebookEntryRecord(novel: Fixture.novel, entryKind: .known(.decision), topic: "t", statement: "s", supersedes: id)
    try await append(next, in: store)
    #expect(try await states(in: store) == [next.id: .active])
    try await append(NotebookEntryRecord(id: id, novel: Fixture.novel, entryKind: .known(.decision), topic: "t", statement: "old"), in: store)
    #expect(try await states(in: store) == [next.id: .active, id: NotebookEntryState(successor: next.id, withdrawal: nil)])
  }

  @Test func shouldDropTheRowsOfAPurgedEntryAndRestoreTheStateWhenAWithdrawalIsPurged() async throws {
    let (store, _) = try derivedStore()
    let entry = NotebookEntryRecord(novel: Fixture.novel, entryKind: .known(.decision), topic: "t", statement: "s")
    let withdrawal = NotebookWithdrawalRecord(novel: Fixture.novel, entry: entry.id, reason: "r")
    try await append(entry, in: store)
    try await append(withdrawal, in: store)
    #expect(try await states(in: store)[entry.id]?.status == .withdrawn)
    try await Projection.purge(withdrawal.ref, in: store)
    #expect(try await states(in: store) == [entry.id: .active])
    try await Projection.purge(entry.ref, in: store)
    #expect(try await rows(in: store).isEmpty)
  }

  @Test func shouldSkipAnEntryItCannotReadWithoutAFault() async throws {
    let (store, reconciler) = try derivedStore()
    try await Projection.createNovel(Fixture.novel, in: store)
    let readable = try await record(Fixture.decision(), in: store)
    _ = try await Projection.write(store) { transaction in
      try transaction.append(NovelForgeKey.notebookEntry(UUID()), item: ["novel": .string(Fixture.novel.uuidString.lowercased())])
    }
    #expect(try await states(in: store) == [readable.id: .active])
    #expect(try await Projection.faults(reconciler, in: store).isEmpty)
  }

  @Test func shouldLeaveTheRowsAloneWhenTheNovelIsRenamed() async throws {
    let (store, reconciler) = try derivedStore()
    try await Projection.createNovel(Fixture.novel, in: store)
    _ = try await record(Fixture.decision(), in: store)
    let before = try await Projection.derived(reconciler, in: store)[NotebookEntryStateRow.databaseTableName]
    try await Projection.renameNovel(Fixture.novel, to: "Salt", in: store)
    #expect(try await Projection.derived(reconciler, in: store)[NotebookEntryStateRow.databaseTableName] == before)
  }

  @Test func shouldEqualARebuild() async throws {
    let (store, reconciler) = try derivedStore()
    try await Projection.createNovel(Fixture.novel, in: store)
    let first = try await record(Fixture.decision("a"), in: store)
    let next = try await Projection.write(store) { transaction in
      try Notebook.supersedeByAuthor(first.id, rewrite: NotebookRewrite(statement: "New"), novel: Fixture.novel, in: &transaction)
    }
    _ = try await Projection.write(store) { transaction in try Notebook.withdraw(next.id, reason: "x", novel: Fixture.novel, in: &transaction) }
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
    #expect(comparison.incremental[NotebookEntryStateRow.databaseTableName]?.count == 2)
  }
}
