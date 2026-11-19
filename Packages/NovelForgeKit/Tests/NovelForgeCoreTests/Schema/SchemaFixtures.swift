import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore
import Synchronization

final class SchemaTestClock: Sendable {
  private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

  var function: @Sendable () -> Date { { self.date.withLock { $0 } } }

  func advance() {
    date.withLock { $0 = $0.addingTimeInterval(1) }
  }
}

struct SchemaFixtureError: Error, CustomStringConvertible {
  let description: String
}

enum SchemaFixture {
  static let registry = NovelForgeSchema.registry
  static let novel = uuid("6f0c4d1e-0000-4000-8000-000000000001")
  static let otherNovel = uuid("6f0c4d1e-0000-4000-8000-000000000002")
  static let proposal = uuid("6f0c4d1e-0000-4000-8000-0000000000a1")
  static let review = uuid("6f0c4d1e-0000-4000-8000-0000000000b1")
  static let draftRevision = "v:00112233445566778899aabbccddeeff00112233"
  static let requester = ReplicaID(uuid("6f0c4d1e-0000-4000-8000-0000000000c1"))

  static func uuid(_ text: String) -> UUID {
    guard let id = UUID(uuidString: text) else { preconditionFailure("\(text) is a valid UUID") }
    return id
  }

  static func store(_ clock: SchemaTestClock = SchemaTestClock()) throws -> VaultStore {
    try VaultStore.open(.inMemory, registry: registry, wallClock: clock.function)
  }

  static func naturalKeys(novel: UUID, text: String = "aria") throws -> [NovelForgeKey] {
    let components: [NovelForgeKey.Components] = [
      .volume(text), .milestone(text), .thread(text), .mystery(text), .secret(text), .entity(text), .characterKnowledge(fact: text, entity: text),
      .page(section: .known(.world), slug: text), .chapterPlan(chapter: 3), .draft(chapter: 3), .finalChapter(chapter: 3), .authorNotes,
      .proposalChange(proposal: proposal, index: 3), .reviewRemedy(review: review, finding: text),
      .finalizeDecision(chapter: 3, draftRevision: draftRevision, item: text),
    ]
    return try components.map { components throws(NovelForgeKeyError) in try NovelForgeKey(novel: novel, components) }
  }

  static func set(_ ref: EntityRef, _ fields: [String: JSONValue], in store: VaultStore) async throws {
    _ = try await store.write { transaction in try transaction.set(ref, fields) }
  }

  static func revise(_ ref: EntityRef, _ body: JSONValue, marks: [String] = [], in store: VaultStore) async throws -> String {
    try await store.write { transaction in try transaction.revise(ref, body: body, marks: marks).revision }
  }

  static func state(_ ref: EntityRef, in store: VaultStore) async throws -> EntityState? {
    try await store.read { transaction in try transaction.state(of: ref) }
  }

  static func record(_ ref: EntityRef, in store: VaultStore) async throws -> RecordState {
    guard case .record(let record)? = try await state(ref, in: store) else { throw SchemaFixtureError(description: "\(ref.kind)/\(ref.key) is not a record") }
    return record
  }

  static func document(_ ref: EntityRef, in store: VaultStore) async throws -> RevisionedState {
    guard case .revisioned(let document)? = try await state(ref, in: store) else { throw SchemaFixtureError(description: "\(ref.kind)/\(ref.key) is not a document") }
    return document
  }

  static func count(_ kind: NovelForgeKind, in store: VaultStore) async throws -> Int {
    try await store.read { transaction in try transaction.states(ofKind: kind.entityKind).count }
  }
}

struct Devices {
  let clock = SchemaTestClock()
  let first: VaultStore
  let second: VaultStore

  init() throws {
    first = try SchemaFixture.store(clock)
    second = try SchemaFixture.store(clock)
  }

  func exchange() async throws {
    let fromFirst = try await first.pendingChanges(limit: Int.max).map(\.line)
    let fromSecond = try await second.pendingChanges(limit: Int.max).map(\.line)
    _ = try await second.applyRemote(fromFirst)
    _ = try await first.applyRemote(fromSecond)
  }

  var both: [VaultStore] { [first, second] }
}
