import Foundation
import GRDB
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

let readNovel = SchemaFixture.novel
let readOtherNovel = SchemaFixture.otherNovel

enum ReadWorld {
  static func store(allowingFaults: Bool = false) throws -> VaultStore {
    try Projection.store(try Projection.reconciler(), allowingFaults: allowingFaults)
  }

  static func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
    _ = try await Projection.write(store) { transaction in try body(&transaction) }
  }

  static func seeded(allowingFaults: Bool = false) async throws -> VaultStore {
    let store = try store(allowingFaults: allowingFaults)
    try await write(store) { transaction in
      _ = try NovelRecord(id: readNovel, name: "Ember").create(in: &transaction)
      _ = try NovelRecord(id: readOtherNovel, name: "Alder", archived: true).create(in: &transaction)
      try PlanWorldWrites.secret(novel: readNovel, "heir", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.milestone(novel: readNovel, "rise", in: &transaction)
      try PlanWorldWrites.milestone(novel: readNovel, "fall", in: &transaction)
      try PlanWorldWrites.volume(novel: readNovel, "one", ordinal: 1, in: &transaction)
      try PlanWorldWrites.volume(novel: readNovel, "two", ordinal: 2, in: &transaction)
      try ChapterWrites.entity(novel: readNovel, "mara", in: &transaction)
      for chapter in 1...4 {
        let learns = chapter == 1 ? [Learn("mara", "heir")] : []
        let claims = chapter == 2 ? ["rise"] : []
        try PlanWorldWrites.putPlan(novel: readNovel, chapter: chapter, planContent(volume: "one", contract(learns: learns, claims: claims)), in: &transaction)
      }
    }
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: readNovel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: readNovel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.finalize(novel: readNovel, chapter: 1, in: &transaction) }
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: readNovel, chapter: 2, in: &transaction)
      try ChapterWrites.approve(novel: readNovel, chapter: 2, in: &transaction)
      try ChapterWrites.draft(novel: readNovel, chapter: 3, in: &transaction)
    }
    return store
  }

  static func insertFault(_ derivation: String, key: String, in store: VaultStore) async throws {
    try await store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT OR REPLACE INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'probe')", arguments: [derivation, key])
    }
  }
}

actor Collected<Value: Sendable> {
  private(set) var values: [Value] = []

  func add(_ value: Value) { values.append(value) }

  func wait(for count: Int) async -> Bool {
    for _ in 0..<100 {
      if values.count >= count { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }
}

func collect<Value: Sendable>(_ stream: AsyncThrowingStream<Value, any Error>) -> (Collected<Value>, Task<Void, Never>) {
  let collected = Collected<Value>()
  let task = Task {
    do {
      for try await value in stream { await collected.add(value) }
    } catch {}
  }
  return (collected, task)
}
