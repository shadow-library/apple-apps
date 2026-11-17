import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

private func disclosed(_ store: VaultStore) async throws -> [String: Int] {
  try await ChapterTables.disclosure(novel, in: store)
}

private func finalize(_ store: VaultStore, teaching key: String) async throws {
  try await write(store) { transaction in
    let canon = Canon(draftRevision: "v:draft", planRevision: "v:plan", body: "Final.", contract: contract(learns: [Learn("mara", key)]), disclosed: [key])
    _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: canon).finalize(in: &transaction)
  }
}

private func expectRebuilt(_ reconciler: NovelForgeReconciler, _ store: VaultStore) async throws {
  let comparison = try await Projection.compare(reconciler, in: store)
  #expect(comparison.incremental == comparison.rebuilt)
}

@Suite("Reader disclosure across devices", .timeLimit(.minutes(2)))
struct ReaderDisclosureReplicaTests {
  @Test func shouldDiscloseWhatTheCanonThatWonAConcurrentFinalizeTeaches() async throws {
    let reconciler = try Projection.reconciler(chapterAreaDerivations)
    let (early, late) = (SchemaTestClock(), SchemaTestClock())
    let (first, second) = (try Projection.store(reconciler, clock: early), try Projection.store(reconciler, clock: late))
    try await write(first) { transaction in
      for key in ["heir", "tide"] { try PlanWorldWrites.secret(novel: novel, key, revealChapter: 1, in: &transaction) }
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
    }
    try await Projection.apply(try await Projection.lines(of: first), to: second)
    for _ in 0..<3 { late.advance() }
    try await finalize(second, teaching: "tide")
    early.advance()
    try await finalize(first, teaching: "heir")
    #expect(try await disclosed(first) == ["heir": 1])
    #expect(try await disclosed(second) == ["tide": 1])

    try await Projection.apply(try await Projection.lines(of: second), to: first)
    try await Projection.apply(try await Projection.lines(of: first), to: second)
    #expect(try await disclosed(first) == ["heir": 1])
    #expect(try await disclosed(second) == ["heir": 1])
    try await expectRebuilt(reconciler, second)
  }

  @Test func shouldNotDiscloseASecretTheFinalizingDeviceDidNotHaveWhenAnEarlierCreationArrives() async throws {
    let reconciler = try Projection.reconciler(chapterAreaDerivations)
    let (writer, offline) = (SchemaTestClock(), SchemaTestClock())
    let (store, other) = (try Projection.store(reconciler, clock: writer), try Projection.store(reconciler, clock: offline))
    try await write(other) { transaction in try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction) }
    writer.advance()
    try await write(store) { transaction in
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    writer.advance()
    try await write(store) { transaction in try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction) }
    #expect(try await disclosed(store).isEmpty)
    #expect(try await ChapterTables.knowledge(novel, in: store).isEmpty)

    try await Projection.apply(try await Projection.lines(of: other), to: store)
    #expect(try await ChapterTables.recorded(in: store) == [[]])
    #expect(try await disclosed(store).isEmpty)
    #expect(try await ChapterTables.knowledge(novel, in: store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    try await expectRebuilt(reconciler, store)
  }

  @Test func shouldDiscloseNothingOfASecretAnotherDeviceRemovedWhileTheChapterWasFinalized() async throws {
    let reconciler = try Projection.reconciler(chapterAreaDerivations)
    let (finalizing, removing) = (SchemaTestClock(), SchemaTestClock())
    let (first, second) = (try Projection.store(reconciler, clock: finalizing), try Projection.store(reconciler, clock: removing))
    try await write(first) { transaction in try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction) }
    try await Projection.apply(try await Projection.lines(of: first), to: second)
    removing.advance()
    try await write(second) { transaction in _ = try SecretRecord.remove(novel: novel, secret: "heir", in: &transaction) }
    for _ in 0..<3 { finalizing.advance() }
    try await finalize(first, teaching: "heir")
    #expect(try await disclosed(first) == ["heir": 1])

    try await Projection.apply(try await Projection.lines(of: second), to: first)
    try await Projection.apply(try await Projection.lines(of: first), to: second)
    #expect(try await disclosed(first).isEmpty)
    #expect(try await disclosed(second).isEmpty)
    try await write(second) { transaction in
      _ = try SecretRecord(novel: novel, secret: "heir", text: "Again.", revealChapter: 1, unlock: nil, source: .known(.manual)).restore(in: &transaction)
    }
    #expect(try await disclosed(second).isEmpty)
    try await expectRebuilt(reconciler, second)
  }
}
