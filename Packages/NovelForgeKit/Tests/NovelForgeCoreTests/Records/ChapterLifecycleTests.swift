import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private struct Chapter {
  let plan: ChapterPlanRecord
  let draft: DraftRecord

  init(_ number: Int, novel: UUID = novel) throws {
    plan = try ChapterPlanRecord(novel: novel, chapter: number, content: ChapterPlanContent(body: "plan \(number)"))
    draft = try DraftRecord(novel: novel, chapter: number, content: DraftContent(body: "draft \(number)", source: .known(.generated)))
  }

  func create(on index: Int, in replicas: CausalReplicas) async throws {
    let (plan, draft) = (plan, draft)
    _ = try await replicas.write(index) { transaction in
      _ = try plan.create(in: &transaction)
      return try draft.create(in: &transaction)
    }
  }

  func heads<Transaction: StateReading & ~Copyable>(in transaction: borrowing Transaction) throws -> (plan: String, draft: String) {
    let plan = try ChapterPlanRecord.history(self.plan.ref, in: transaction).history?.head
    let draft = try DraftRecord.history(self.draft.ref, in: transaction).history?.head
    guard let plan, let draft else { throw SchemaFixtureError(description: "chapter \(self.plan.chapter) has no heads") }
    return (plan, draft)
  }

  func approve(id: UUID, in transaction: inout WriteTransaction) throws -> ApprovalRecord {
    let (planHead, draftHead) = try heads(in: transaction)
    let approval = ApprovalRecord(id: id, novel: plan.novel, chapter: plan.chapter, draftRevision: draftHead, planRevision: planHead)
    _ = try approval.append(in: &transaction)
    return approval
  }
}

private func inForce(_ chapter: Int, in store: VaultStore, novel: UUID = novel) async throws -> ApprovalRecord? {
  try await store.read { transaction in try ApprovalRecord.inForce(novel: novel, chapter: chapter, in: transaction) }?.record
}

@Suite("Approval in force and withdrawn Notebook entries", .timeLimit(.minutes(2)))
struct ChapterLifecycleTests {
  @Test func shouldPutTheLatestApprovalOfBothCurrentHeadsInForce() async throws {
    let store = try SchemaFixture.store()
    let chapter = try Chapter(3)
    #expect(try await inForce(3, in: store) == nil)
    _ = try await Harness.create(chapter.plan, in: store)
    _ = try await Harness.create(chapter.draft, in: store)
    #expect(try await inForce(3, in: store) == nil)

    let first = try await store.write { transaction in try chapter.approve(id: UUID(), in: &transaction) }
    #expect(try await inForce(3, in: store) == first)
    let second = try await store.write { transaction in try chapter.approve(id: UUID(), in: &transaction) }
    #expect(try await inForce(3, in: store) == second)

    let other = try Chapter(4)
    _ = try await Harness.create(other.plan, in: store)
    _ = try await Harness.create(other.draft, in: store)
    _ = try await store.write { transaction in try other.approve(id: UUID(), in: &transaction) }
    #expect(try await inForce(3, in: store) == second)

    let draftRef = chapter.draft.ref
    _ = try await store.write { transaction in try DraftRecord.revise(draftRef, DraftContent(body: "edited", source: .known(.handEdited)), in: &transaction) }
    #expect(try await inForce(3, in: store) == nil)
    let third = try await store.write { transaction in try chapter.approve(id: UUID(), in: &transaction) }
    #expect(try await inForce(3, in: store) == third)

    let planRef = chapter.plan.ref
    _ = try await store.write { transaction in try ChapterPlanRecord.revise(planRef, ChapterPlanContent(body: "replanned"), in: &transaction) }
    #expect(try await inForce(3, in: store) == nil)
  }

  @Test func shouldPutNoApprovalInForceWhileThePlanOrTheDraftIsRemoved() async throws {
    let store = try SchemaFixture.store()
    let chapter = try Chapter(2)
    _ = try await Harness.create(chapter.plan, in: store)
    _ = try await Harness.create(chapter.draft, in: store)
    let approval = try await store.write { transaction in try chapter.approve(id: UUID(), in: &transaction) }
    _ = try await Harness.remove(chapter.draft, in: store)
    #expect(try await inForce(2, in: store) == nil)
    _ = try await Harness.restore(chapter.draft, in: store)
    #expect(try await inForce(2, in: store) == approval)
    _ = try await Harness.remove(chapter.plan, in: store)
    #expect(try await inForce(2, in: store) == nil)
    #expect(try await inForce(0, in: store) == nil)
  }

  @Test func shouldBreakATieOnTheClockByTheApprovalId() async throws {
    let store = try SchemaFixture.store()
    let witness = ApprovalRecord(novel: novel, chapter: 9, draftRevision: "v:w", planRevision: "v:w")
    let clock = try await store.write { transaction in try witness.append(in: &transaction) }.clock
    let low = SchemaFixture.uuid("00000000-0000-4000-8000-000000000001")
    let high = SchemaFixture.uuid("ffffffff-0000-4000-8000-000000000001")
    let entries = [high, low].map { id in
      AppendedEntry(record: ApprovalRecord(id: id, novel: novel, chapter: 1, draftRevision: "v:d", planRevision: "v:p"), clock: clock)
    }
    #expect(ApprovalRecord.inForce(among: entries, novel: novel, chapter: 1, planRevision: "v:p", draftRevision: "v:d")?.record.id == high)
    #expect(ApprovalRecord.inForce(among: entries.reversed(), novel: novel, chapter: 1, planRevision: "v:p", draftRevision: "v:d")?.record.id == high)
    #expect(ApprovalRecord.inForce(among: entries, novel: novel, chapter: 2, planRevision: "v:p", draftRevision: "v:d") == nil)
    #expect(ApprovalRecord.inForce(among: entries, novel: SchemaFixture.otherNovel, chapter: 1, planRevision: "v:p", draftRevision: "v:d") == nil)
    #expect(ApprovalRecord.inForce(among: entries, novel: novel, chapter: 1, planRevision: "v:d", draftRevision: "v:p") == nil)
  }

  @Test func shouldAgreeOnTheApprovalInForceAcrossReplicas() async throws {
    try await forAll(iterations: 12, seed: 0x4A1) { generator in
      let replicas = try await replicas(seed: generator.next())
      let id = generator.uuid()
      let chapter = try Chapter(1, novel: id)
      try await chapter.create(on: 0, in: replicas)
      try await replicas.settle()
      let draftRef = chapter.draft.ref
      for _ in 0..<8 {
        let index = generator.int(in: 0...(replicas.count - 1))
        switch generator.int(in: 0...9) {
        case 0..<4:
          let approvalID = generator.uuid()
          _ = try await replicas.write(index) { transaction in try chapter.approve(id: approvalID, in: &transaction) }
        case 4..<5:
          let content = Gen.draftContent(&generator)
          _ = try await replicas.write(index) { transaction in try DraftRecord.revise(draftRef, content, in: &transaction) }
        case 5..<7:
          await replicas.advanceClock(of: index, by: .seconds(generator.int(in: 1...3)))
        default:
          _ = try await replicas.step(using: &generator)
        }
      }
      try await replicas.settle()
      var results = [ApprovalRecord?]()
      for index in 0..<replicas.count { results.append(try await inForce(1, in: await replicas.store(index), novel: id)) }
      for result in results.dropFirst() { #expect(result == results[0]) }

      let expected = try await replicas.store(0).read { transaction in
        let (plan, draft) = try chapter.heads(in: transaction)
        let matching = try ApprovalRecord.listing(novel: id, in: transaction).entries.filter { $0.record.approves(planRevision: plan, draftRevision: draft) }
        return matching.last?.record
      }
      #expect(results[0] == expected)
    }
  }

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
