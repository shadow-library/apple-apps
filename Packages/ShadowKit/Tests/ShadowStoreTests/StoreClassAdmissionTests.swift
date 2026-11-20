import Foundation
import ShadowCore
import Testing

@testable import ShadowStore

private enum ClassFixture {
  static let vital = must(EntityKind("vital"), "vital")
  static let steps = must(EntityKind("steps"), "steps")

  static let general = SchemaRegistry(version: 1, entities: [EntitySchema(kind: Fixture.note, shape: .record(fields: ["title": .register]), syncClass: .general)])
  static let mixed = SchemaRegistry(
    version: 1,
    entities: [
      EntitySchema(kind: Fixture.note, shape: .record(fields: ["title": .register]), syncClass: .general),
      EntitySchema(kind: steps, shape: .record(fields: ["count": .register]), syncClass: .activity),
      EntitySchema(kind: vital, shape: .record(fields: ["value": .register]), syncClass: .health),
    ])
}

@Suite("VaultStore sync class admission", TestTimeLimit.standard)
struct StoreClassAdmissionTests {
  private func refusal(_ body: () throws -> VaultStore) -> (kind: EntityKind, syncClass: SyncClass)? {
    let error = #expect(throws: StoreError.self) { _ = try body() }
    guard case .syncClassNotAdmitted(let kind, let syncClass) = error else {
      Issue.record("expected a sync class refusal, got \(String(describing: error))")
      return nil
    }
    return (kind, syncClass)
  }

  @Test("should admit every class by default")
  func shouldAdmitEveryClassByDefault() async throws {
    let store = try VaultStore.open(.inMemory, registry: ClassFixture.mixed)
    try await store.write { transaction in
      _ = try transaction.set(EntityRef(kind: ClassFixture.vital, key: Fixture.key("weight")), ["value": 72])
    }
    #expect(try await store.allPending.count == 1)
  }

  @Test("should refuse a registry declaring a kind outside the admitted classes and name the first such kind")
  func shouldRefuseAnUnadmittedKind() {
    let refused = refusal { try VaultStore.open(.inMemory, registry: ClassFixture.mixed, admittedClasses: [.general]) }
    #expect(refused?.kind == ClassFixture.steps)
    #expect(refused?.syncClass == .activity)
  }

  @Test("should refuse the health kind when activity is admitted beside general")
  func shouldRefuseHealthBesideActivity() {
    let refused = refusal { try VaultStore.open(.inMemory, registry: ClassFixture.mixed, admittedClasses: [.general, .activity]) }
    #expect(refused?.kind == ClassFixture.vital)
    #expect(refused?.syncClass == .health)
  }

  @Test("should refuse every declared kind when no class is admitted and open an empty registry")
  func shouldHandleAnEmptyAdmission() throws {
    let refused = refusal { try VaultStore.open(.inMemory, registry: ClassFixture.general, admittedClasses: []) }
    #expect(refused?.kind == Fixture.note)
    _ = try VaultStore.open(.inMemory, registry: SchemaRegistry(version: 1, entities: []), admittedClasses: [])
  }

  @Test("should refuse before touching the disk")
  func shouldRefuseBeforeTouchingTheDisk() {
    let directory = TemporaryDirectory()
    _ = refusal { try VaultStore.open(.file(directory.storeURL), registry: ClassFixture.mixed, admittedClasses: [.general]) }
    #expect(!FileManager.default.fileExists(atPath: directory.url.path(percentEncoded: false)))
  }

  @Test("should refuse a reopen with a narrower admission and leave the stored rows alone")
  func shouldRefuseANarrowerReopen() async throws {
    let directory = TemporaryDirectory()
    let store = try VaultStore.open(.file(directory.storeURL), registry: ClassFixture.mixed)
    try await store.write { transaction in
      _ = try transaction.set(EntityRef(kind: ClassFixture.vital, key: Fixture.key("weight")), ["value": 72])
    }
    _ = refusal { try VaultStore.open(.file(directory.storeURL), registry: ClassFixture.mixed, admittedClasses: [.general]) }
    let reopened = try VaultStore.open(.file(directory.storeURL), registry: ClassFixture.mixed)
    let state = try await reopened.read { try $0.state(of: EntityRef(kind: ClassFixture.vital, key: Fixture.key("weight"))) }
    #expect(state != nil)
  }

  @Test("should refuse a write of a kind outside the admitted classes because the registry does not declare it")
  func shouldRefuseAWriteOfAnUndeclaredKind() async throws {
    let store = try VaultStore.open(.inMemory, registry: ClassFixture.general, admittedClasses: [.general])
    let error = await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        _ = try transaction.set(EntityRef(kind: ClassFixture.vital, key: Fixture.key("weight")), ["value": 72])
      }
    }
    guard case .invalidChange = error else {
      Issue.record("expected an invalid change, got \(String(describing: error))")
      return
    }
    #expect(try await store.allPending.isEmpty)
    let stored = try await store.read { try $0.state(of: EntityRef(kind: ClassFixture.vital, key: Fixture.key("weight"))) }
    #expect(stored == nil)
  }
}
