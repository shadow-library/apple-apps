import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowSync

private let mine = ReplicaFixture.replica("01936f3e-1111-7111-8111-111111111111")
private let theirs = ReplicaFixture.replica("01936f3e-2222-7222-8222-222222222222")

private struct ReplicaHistorySnapshot: Equatable {
  let uploads: ReplicaUploadHistory
  let head: StreamPoint?
  let base: BaseReference?

  init(_ store: VaultStore, _ replica: ReplicaID) async throws {
    (uploads, head, base) = try await store.read { transaction in
      (
        try ReplicaHistory.uploads(of: replica, in: transaction.database), try ReplicaHistory.head(of: replica, in: transaction.database),
        try ReplicaHistory.currentBase(of: replica, in: transaction.database)
      )
    }
  }

  var isEmpty: Bool {
    uploads == ReplicaUploadHistory() && head == nil && base == nil
  }
}

private func record(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  try await store.write(body)
}

private func base(_ upTo: Int64, _ tag: Int, parts: Int) throws -> BaseReference {
  guard let base = BaseReference(upTo: upTo, tag: ReplicaFixture.tag(tag), parts: parts) else { throw ReplicaFixtureFailure("base") }
  return base
}

@Suite("ReplicaHistory")
struct ReplicaHistoryTests {
  @Test("should record segments and bases and answer head and current base")
  func shouldRecord() async throws {
    let store = try ReplicaFixture.open()
    #expect(try await ReplicaHistorySnapshot(store, mine).isEmpty)
    try await record(store) { transaction in
      let db = transaction.database
      try ReplicaHistory.recordSegment(ReplicaFixture.point(5, 1), first: 1, replica: mine, at: 10, in: db)
      try ReplicaHistory.recordSegment(ReplicaFixture.point(9, 2), first: 6, replica: mine, at: 11, in: db)
      try ReplicaHistory.recordBase(ReplicaFixture.point(5, 3), parts: 2, replica: mine, at: 12, in: db)
    }
    var snapshot = try await ReplicaHistorySnapshot(store, mine)
    #expect(snapshot.uploads == ReplicaUploadHistory(segments: [ReplicaFixture.point(5, 1), ReplicaFixture.point(9, 2)], bases: [ReplicaFixture.point(5, 3)]))
    #expect(snapshot.head == ReplicaFixture.point(9, 2))
    #expect(snapshot.base == (try base(5, 3, parts: 2)))

    try await record(store) { transaction in
      let db = transaction.database
      try ReplicaHistory.recordBase(ReplicaFixture.point(9, 4), parts: 1, replica: mine, at: 13, in: db)
      try ReplicaHistory.markDeleted(ReplicaFixture.point(5, 3), isBase: true, replica: mine, at: 14, in: db)
      try ReplicaHistory.markDeleted(ReplicaFixture.point(5, 1), isBase: false, replica: mine, at: 14, in: db)
      try ReplicaHistory.markDeleted(ReplicaFixture.point(9, 2), isBase: false, replica: mine, at: 14, in: db)
    }
    snapshot = try await ReplicaHistorySnapshot(store, mine)
    #expect(snapshot.uploads.segments == [ReplicaFixture.point(5, 1), ReplicaFixture.point(9, 2)])
    #expect(snapshot.uploads.bases == [ReplicaFixture.point(5, 3), ReplicaFixture.point(9, 4)])
    #expect(snapshot.head == ReplicaFixture.point(9, 2))
    #expect(snapshot.base == (try base(9, 4, parts: 1)))

    try await record(store) { transaction in try ReplicaHistory.markDeleted(ReplicaFixture.point(9, 4), isBase: true, replica: mine, at: 15, in: transaction.database) }
    #expect(try await ReplicaHistorySnapshot(store, mine).base == nil)
  }

  @Test("should treat recording the same file again as harmless")
  func shouldRecordIdempotently() async throws {
    let store = try ReplicaFixture.open()
    let once: @Sendable (inout WriteTransaction) throws -> Void = { transaction in
      try ReplicaHistory.recordSegment(ReplicaFixture.point(5, 1), first: 1, replica: mine, at: 10, in: transaction.database)
      try ReplicaHistory.recordBase(ReplicaFixture.point(5, 2), parts: 3, replica: mine, at: 10, in: transaction.database)
    }
    try await record(store, once)
    let before = try await ReplicaHistorySnapshot(store, mine)
    try await record(store, once)
    try await record(store) { transaction in
      try ReplicaHistory.markDeleted(ReplicaFixture.point(7, 9), isBase: false, replica: mine, at: 20, in: transaction.database)
      try ReplicaHistory.markDeleted(ReplicaFixture.point(7, 9), isBase: false, replica: mine, at: 21, in: transaction.database)
    }
    let after = try await ReplicaHistorySnapshot(store, mine)
    #expect(after.base == before.base && after.head == ReplicaFixture.point(7, 9))
    #expect(after.uploads.segments == [ReplicaFixture.point(5, 1), ReplicaFixture.point(7, 9)])
  }

  @Test("should reject a part count or sequence out of range")
  func shouldRejectOutOfRange() async throws {
    let store = try ReplicaFixture.open()
    await #expect(throws: StoreError.self) {
      try await record(store) { transaction in try ReplicaHistory.recordBase(ReplicaFixture.point(5, 1), parts: 0, replica: mine, at: 1, in: transaction.database) }
    }
    await #expect(throws: StoreError.self) {
      try await record(store) { transaction in try ReplicaHistory.recordSegment(ReplicaFixture.point(0, 1), first: 1, replica: mine, at: 1, in: transaction.database) }
    }
    await #expect(throws: StoreError.self) {
      try await record(store) { transaction in try ReplicaHistory.recordSegment(ReplicaFixture.point(5, 1), first: 6, replica: mine, at: 1, in: transaction.database) }
    }
  }

  @Test("should keep each replica's history apart and clear only one")
  func shouldIsolateReplicas() async throws {
    let store = try ReplicaFixture.open()
    try await record(store) { transaction in
      try ReplicaHistory.recordSegment(ReplicaFixture.point(5, 1), first: 1, replica: mine, at: 1, in: transaction.database)
      try ReplicaHistory.recordSegment(ReplicaFixture.point(3, 2), first: 1, replica: theirs, at: 1, in: transaction.database)
    }
    #expect(try await ReplicaHistorySnapshot(store, mine).uploads.segments == [ReplicaFixture.point(5, 1)])
    #expect(try await ReplicaHistorySnapshot(store, theirs).uploads.segments == [ReplicaFixture.point(3, 2)])
    try await record(store) { transaction in try ReplicaHistory.clear(replica: theirs, in: transaction.database) }
    #expect(try await ReplicaHistorySnapshot(store, theirs).isEmpty)
    #expect(try await ReplicaHistorySnapshot(store, mine).head == ReplicaFixture.point(5, 1))
  }

  @Test("should survive reopening a file-backed store")
  func shouldPersist() async throws {
    let directory = ReplicaTemporaryDirectory()
    let url = directory.database("history")
    let written = try await {
      let store = try ReplicaFixture.open(.file(url))
      try await record(store) { transaction in
        try ReplicaHistory.recordSegment(ReplicaFixture.point(5, 1), first: 1, replica: mine, at: 1, in: transaction.database)
        try ReplicaHistory.recordBase(ReplicaFixture.point(5, 2), parts: 2, replica: mine, at: 1, in: transaction.database)
        try ReplicaHistory.markDeleted(ReplicaFixture.point(5, 1), isBase: false, replica: mine, at: 2, in: transaction.database)
      }
      return try await ReplicaHistorySnapshot(store, mine)
    }()
    let reopened = try ReplicaFixture.open(.file(url))
    #expect(try await ReplicaHistorySnapshot(reopened, mine) == written)
    #expect(written.base == (try base(5, 2, parts: 2)))
  }
}
