import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

@Suite("Withdrawn Notebook entries", TestTimeLimit.standard)
struct WithdrawnEntryTests {
  @Test func shouldTellWhichNotebookEntriesAreWithdrawnByTheEarliestWithdrawalOfTheirNovel() async throws {
    let store = try SchemaFixture.store()
    let kept = NotebookEntryRecord(novel: novel, entryKind: .known(.decision), topic: "ending", statement: "Kept")
    let dropped = NotebookEntryRecord(novel: novel, entryKind: .known(.direction), topic: "pace", statement: "Dropped")
    let foreign = NotebookEntryRecord(novel: SchemaFixture.otherNovel, entryKind: .known(.decision), topic: "t", statement: "Theirs")
    for entry in [kept, dropped, foreign] { _ = try await store.write { transaction in try entry.append(in: &transaction) } }
    let first = NotebookWithdrawalRecord(novel: novel, entry: dropped.id, reason: "first")
    let second = NotebookWithdrawalRecord(novel: novel, entry: dropped.id, reason: "second")
    let crossNovel = NotebookWithdrawalRecord(novel: novel, entry: foreign.id, reason: "wrong novel")
    let unknown = NotebookWithdrawalRecord(novel: novel, entry: UUID(), reason: "no such entry")
    for withdrawal in [first, second, crossNovel, unknown] { _ = try await store.write { transaction in try withdrawal.append(in: &transaction) } }

    let withdrawn = try await store.read { transaction in try NotebookEntryRecord.withdrawals(novel: novel, in: transaction) }
    #expect(withdrawn.mapValues(\.record) == [dropped.id: first])
    let theirs = try await store.read { transaction in try NotebookEntryRecord.withdrawals(novel: SchemaFixture.otherNovel, in: transaction) }
    #expect(theirs.isEmpty)
  }

  @Test func shouldAgreeOnWithdrawnEntriesAcrossReplicas() async throws {
    try await forAll(iterations: 6, seed: 0x4A2) { generator in
      let replicas = try await replicas(seed: generator.next())
      let id = generator.uuid()
      let entry = Gen.notebookEntry(&generator, novel: id)
      _ = try await replicas.write(0) { transaction in try entry.append(in: &transaction) }
      try await replicas.settle()
      let (left, right) = (Gen.withdrawal(&generator, novel: id, entry: entry.id), Gen.withdrawal(&generator, novel: id, entry: entry.id))
      _ = try await replicas.write(1) { transaction in try left.append(in: &transaction) }
      await replicas.advanceClock(of: 2, by: .seconds(5))
      _ = try await replicas.write(2) { transaction in try right.append(in: &transaction) }
      try await replicas.settle()
      for index in 0..<replicas.count {
        let withdrawn = try await replicas.store(index).read { transaction in try NotebookEntryRecord.withdrawals(novel: id, in: transaction) }
        #expect(withdrawn.mapValues(\.record) == [entry.id: left])
      }
    }
  }
}
