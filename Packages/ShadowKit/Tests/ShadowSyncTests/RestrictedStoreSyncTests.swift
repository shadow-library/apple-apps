import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Restricted store sync", TestTimeLimit.standard)
struct RestrictedStoreSyncTests {
  private static let generalRegistry = SyncKernelSchema.registry(version: 3, adding: [SyncFixture.entities[0]])
  private static let weight = EntityRef(kind: SyncFixture.vital, key: ReplicaFixture.key("weight"))

  private final class Directory {
    let url = FileManager.default.temporaryDirectory.appending(path: "shadow-restricted-\(UUID().uuidString)", directoryHint: .isDirectory)

    var database: URL { url.appending(path: "health.sqlite") }

    deinit {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func settles(on expected: Bool, _ url: URL) async throws -> Bool {
    for _ in 0..<6_000 {
      if BackupExclusion.isExcluded(url) == expected { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  private func openRestricted(_ directory: Directory) throws -> VaultStore {
    try VaultStore.open(.file(directory.database), registry: SyncFixture.registry, migrations: SyncEngine.migrations, wallClock: { SyncFixture.start }, backup: .alwaysExcluded)
  }

  private func storedRecords(_ harness: SyncHarness) async throws -> [ChangeRecord] {
    try await SyncPlant.records(in: harness.provider, ring: harness.ring) + SyncPlant.baseRecords(in: harness.provider, ring: harness.ring)
  }

  @Test("should put no object for a health-class kind on an iCloud provider and refuse the whole upload")
  func shouldRefuseHealthOnICloud() async throws {
    let directory = Directory()
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let harness = try await SyncHarness.started(store: try openRestricted(directory), provider: provider)
    try await harness.writeNotes(1)
    try await harness.store.write { transaction in _ = try transaction.set(Self.weight, ["value": .int(72)]) }
    let pending = try await harness.pendingLines()

    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .syncClassRefused(SyncFixture.vital, .health)? = error else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: error))") }
    let compaction = await #expect(throws: SyncError.self) { try await harness.engine.compact(force: true) }
    guard case .syncClassRefused(SyncFixture.vital, .health)? = compaction else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: compaction))") }

    #expect(provider.callCounts.put == 0)
    #expect(try await storedRecords(harness).isEmpty)
    #expect(try await harness.pendingLines() == pending)
  }

  @Test("should upload the general kinds of a store admitting only the general class to an iCloud provider")
  func shouldUploadTheMainStoreToICloud() async throws {
    let store = try VaultStore.open(.inMemory, registry: Self.generalRegistry, migrations: SyncEngine.migrations, wallClock: { SyncFixture.start }, admittedClasses: [.general])
    let harness = try await SyncHarness.started(store: store, provider: InMemoryStorageProvider(classPolicy: .iCloud))
    try await harness.writeNotes(2)

    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    let kinds = Set(try await storedRecords(harness).map(\.entity))
    #expect(kinds.contains(SyncFixture.note))
    #expect(!kinds.contains(SyncFixture.vital))
    #expect(try await harness.pendingLines().isEmpty)
  }

  @Test("should refuse to open a store admitting only the general class with a registry declaring a health kind")
  func shouldRefuseHealthInTheMainStore() {
    let error = #expect(throws: StoreError.self) {
      try VaultStore.open(.inMemory, registry: SyncFixture.registry, migrations: SyncEngine.migrations, admittedClasses: [.general])
    }
    guard case .syncClassNotAdmitted(SyncFixture.vital, .health)? = error else {
      Issue.record("expected the class admission refusal, got \(String(describing: error))")
      return
    }
  }

  @Test("should upload the restricted store's health records to an unrestricted provider")
  func shouldUploadHealthWhereAllowed() async throws {
    let directory = Directory()
    let harness = try await SyncHarness.started(store: try openRestricted(directory))
    try await harness.store.write { transaction in _ = try transaction.set(Self.weight, ["value": .int(72)]) }

    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    #expect(try await storedRecords(harness).contains { $0.entity == SyncFixture.vital })
  }

  @Test("should keep the restricted store out of device backups when storage is detached")
  func shouldKeepTheExclusionOnDetach() async throws {
    let directory = Directory()
    let harness = try await SyncHarness.started(store: try openRestricted(directory))
    #expect(await harness.engine.backupExclusionFailure == nil)
    #expect(try await settles(on: true, directory.url))

    let failure = StorageAttachment.detach(harness.store)
    guard case .backupExclusionPinned? = failure else {
      Issue.record("expected the pinned exclusion error, got \(String(describing: failure))")
      return
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(BackupExclusion.isExcluded(directory.url))
  }
}
