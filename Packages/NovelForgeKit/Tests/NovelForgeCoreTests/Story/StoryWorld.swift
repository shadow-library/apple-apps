import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

typealias StoryBody = @Sendable (inout WriteTransaction) throws -> Void

struct StoryWorld: Sendable {
  let store: VaultStore
  let novel: UUID

  /// `reconciled` keeps the derived state current, which a fact removal reads for the knowledge it would orphan.
  static func make(withNovel: Bool = true, reconciled: Bool = false) async throws -> StoryWorld {
    let store = reconciled ? try Projection.store(try Projection.reconciler()) : try SchemaFixture.store()
    let world = StoryWorld(store: store, novel: SchemaFixture.novel)
    if withNovel { _ = try await Harness.create(NovelRecord(id: world.novel, name: "Ember"), in: world.store) }
    return world
  }

  func run(_ body: StoryBody) async throws {
    try await store.write(body)
  }

  func expect(_ expected: DomainError, _ body: StoryBody, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
      try await store.write(body)
      Issue.record("expected \(expected.code) but the operation succeeded", sourceLocation: sourceLocation)
    } catch {
      guard case .aborted(let cause) = error else {
        Issue.record("expected \(expected.code) but got \(error)", sourceLocation: sourceLocation)
        return
      }
      #expect(cause as? DomainError == expected, sourceLocation: sourceLocation)
    }
  }

  func seed(_ records: any NovelForgeRecord...) async throws {
    for record in records { try await put(record) }
  }

  private func put<R: NovelForgeRecord>(_ record: R) async throws {
    _ = try await Harness.create(record, in: store)
  }

  func read<T: Sendable>(_ body: @Sendable (ReadTransaction) throws -> T) async throws -> T {
    try await store.read(body)
  }

  func volume(_ key: String) async throws -> RecordReading<VolumeRecord> {
    let novel = novel
    return try await read { try VolumeRecord.read(novel: novel, volume: key, in: $0) }
  }

  func milestone(_ key: String) async throws -> RecordReading<MilestoneRecord> {
    let novel = novel
    return try await read { try MilestoneRecord.read(novel: novel, milestone: key, in: $0) }
  }

  func thread(_ key: String) async throws -> RecordReading<ThreadRecord> {
    let novel = novel
    return try await read { try ThreadRecord.read(novel: novel, thread: key, in: $0) }
  }

  func mystery(_ key: String) async throws -> RecordReading<MysteryRecord> {
    let novel = novel
    return try await read { try MysteryRecord.read(novel: novel, mystery: key, in: $0) }
  }

  func secret(_ key: String) async throws -> RecordReading<SecretRecord> {
    let novel = novel
    return try await read { try SecretRecord.read(novel: novel, secret: key, in: $0) }
  }

  func knowledge(fact: String, entity: String) async throws -> RecordReading<CharacterKnowledgeRecord> {
    let novel = novel
    return try await read { try CharacterKnowledgeRecord.read(novel: novel, fact: fact, entity: entity, in: $0) }
  }

  func pendingChangeCount() async throws -> Int {
    try await store.pendingChanges(limit: Int.max).count
  }

  func entity(_ key: String) -> EntityRecord {
    EntityRecord(novel: novel, entity: key, type: .known(.character), name: key.capitalized)
  }

  func plan(chapter: Int, volume: String? = nil, claims: [String] = []) throws -> ChapterPlanRecord {
    try ChapterPlanRecord(
      novel: novel, chapter: chapter, content: ChapterPlanContent(body: "plan \(chapter)", volume: volume, contract: ChapterContract(claimedMilestones: claims)))
  }

  func draft(chapter: Int) throws -> DraftRecord {
    try DraftRecord(novel: novel, chapter: chapter, content: DraftContent(body: "draft \(chapter)", source: .known(.generated)))
  }

  func final(chapter: Int) throws -> FinalChapterRecord {
    try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(body: "final \(chapter)"))
  }
}

func live<R: Sendable & Equatable>(_ reading: RecordReading<R>) -> R? {
  guard case .readable(let entry) = reading, !entry.isRemoved else { return nil }
  return entry.record
}

func isRemoved<R: Sendable & Equatable>(_ reading: RecordReading<R>) -> Bool {
  guard case .readable(let entry) = reading else { return false }
  return entry.isRemoved
}
