import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Writer snapshots")
struct WriterSnapshotTests {
  private static let novel = SchemaFixture.novel

  private static func capture(_ revision: String, attempt: Int = 1, chapter: Int = 2, isolated: Bool = false) -> WriterSnapshotCapture {
    WriterSnapshotCapture(
      novel: novel, chapter: chapter, revision: revision, attempt: attempt, role: .draft, messages: [WriterSnapshotMessage(role: "user", content: "Write \(revision).")],
      keptBack: ["withheldForSecrecy": ["prose": 1]], planRevision: "plan-1", bibleHash: "bible-1", promptKey: "generation", promptVersion: "2.12.0",
      route: WriterSnapshotRoute(provider: "api.example.com", model: "model-a"), isolated: isolated, run: "run-1")
  }

  private static func id(_ ordinal: Int) -> UUID {
    SchemaFixture.uuid(String(format: "5a000000-0000-4000-8000-%012d", ordinal))
  }

  private static func record(_ captures: [WriterSnapshotCapture], in store: VaultStore) async throws {
    for (index, capture) in captures.enumerated() {
      try await store.write { transaction in
        try WriterSnapshots.record(capture, id: id(index), at: Date(timeIntervalSince1970: Double(1_800_000_000 + index)), in: transaction.database)
      }
    }
  }

  @Test func shouldKeepTheCurrentRevisionAndTheTwoBeforeIt() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await Self.record(
      [Self.capture("r1"), Self.capture("r2"), Self.capture("r2", attempt: 2), Self.capture("r3"), Self.capture("r4"), Self.capture("r4", attempt: 2)], in: store)
    let kept = try await store.writerSnapshots(novel: Self.novel, chapter: 2)
    #expect(kept.map(\.revision) == ["r4", "r4", "r3", "r2", "r2"])
    #expect(kept.map(\.attempt) == [2, 1, 1, 2, 1])
    try await Self.record([Self.capture("r9", chapter: 3)], in: store)
    #expect(try await store.writerSnapshots(novel: Self.novel, chapter: 2).count == 5)
  }

  @Test func shouldWallOffTheMessagesOfAnIsolatedAttempt() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await Self.record([Self.capture("r1"), Self.capture("r2", isolated: true)], in: store)
    let open = try #require(try await store.writerSnapshot(Self.id(0), novel: Self.novel, chapter: 2))
    #expect(open.messages == [WriterSnapshotMessage(role: "user", content: "Write r1.")] && open.bibleHash == "bible-1" && !open.summary.isolated)
    let walled = try #require(try await store.writerSnapshot(Self.id(1), novel: Self.novel, chapter: 2))
    #expect(walled.messages == WriterSnapshots.walledOff && walled.bibleHash == nil && walled.summary.isolated)
    #expect(walled.keptBack == ["withheldForSecrecy": ["prose": 1]] && walled.planRevision == "plan-1")
    #expect(try await store.writerSnapshot(Self.id(0), novel: Self.novel, chapter: 3) == nil)
  }

  @Test func shouldWallOffAnOlderAttemptOnceTheChapterIsIsolatedNow() async throws {
    let store = try Projection.store(try Projection.reconciler())
    let novel = Self.novel
    try await store.write { transaction in
      _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
      _ = try DraftRecord(novel: novel, chapter: 2, content: DraftContent(body: "Walled.", source: .known(.generated), generator: .known(.unrestricted), isolated: true))
        .create(in: &transaction)
    }
    try await Self.record([Self.capture("r1")], in: store)
    let view = try #require(try await store.writerSnapshot(Self.id(0), novel: novel, chapter: 2))
    #expect(view.messages == WriterSnapshots.walledOff && view.summary.isolated)
  }

  @Test func shouldForgetANovelsAttempts() async throws {
    let store = try Projection.store(try Projection.reconciler())
    try await Self.record([Self.capture("r1")], in: store)
    try await store.write { transaction in try WriterSnapshots.forget(novel: Self.novel, in: transaction.database) }
    #expect(try await store.writerSnapshots(novel: Self.novel, chapter: 2).isEmpty)
  }

  @Test func shouldClearTheNovelsSnapshotsAndPinnedPacksWithItsLocalChats() async throws {
    let store = try Projection.store(try Projection.reconciler())
    let (novel, other) = (Self.novel, SchemaFixture.otherNovel)
    try await store.write { transaction in
      for (id, name) in [(novel, "Ember"), (other, "Ash")] { _ = try NovelRecord(id: id, name: name).create(in: &transaction) }
    }
    try await Self.record([Self.capture("r1")], in: store)
    let kept = WriterSnapshotCapture(
      novel: other, chapter: 2, revision: "o1", attempt: 1, role: .draft, messages: [], keptBack: .null, planRevision: nil, bibleHash: nil, promptKey: "generation",
      promptVersion: "2.12.0", route: WriterSnapshotRoute(provider: "api.example.com", model: "model-a"), isolated: false, run: nil)
    try await store.write { transaction in try WriterSnapshots.record(kept, id: Self.id(9), at: Date(timeIntervalSince1970: 1_800_000_000), in: transaction.database) }
    let built = try await vaultWriterPack(store)(novel, 1, WriterPackOptions())
    let pack = PinnedWriterPack(built.pack, disclosure: built.disclosure, sources: built.sources)
    let attempts = [try AttemptID(UUID.v7()), try AttemptID(UUID.v7())]
    try await store.write { transaction in
      for (attempt, owner) in zip(attempts, [novel, other]) {
        _ = try WriterPackPins.pin(pack, options: WriterPackOptions(), attempt: attempt, novel: owner, at: Date(), in: transaction.database)
      }
    }
    try await store.forgetLocalChats(novel: novel)
    #expect(try await store.writerSnapshots(novel: novel, chapter: 2).isEmpty)
    #expect(try await store.writerSnapshots(novel: other, chapter: 2).count == 1)
    let pinned = try await store.read { transaction in
      try attempts.map { attempt in try WriterPackPins.pinned(attempt, options: WriterPackOptions(), in: transaction.database) != nil }
    }
    #expect(pinned == [false, true])
  }
}
