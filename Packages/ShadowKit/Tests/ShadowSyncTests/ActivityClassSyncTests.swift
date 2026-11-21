import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Activity class sync", TestTimeLimit.standard)
struct ActivityClassSyncTests {
  private static let steps = ReplicaFixture.kind("steps")
  private static let registry = SyncKernelSchema.registry(
    version: 3, adding: SyncFixture.entities + [EntitySchema(kind: steps, shape: .record(fields: ["value": .register]), syncClass: .activity)])
  private static let stepsRef = EntityRef(kind: steps, key: ReplicaFixture.key("2026-11-20"))
  private static let weightRef = EntityRef(kind: SyncFixture.vital, key: ReplicaFixture.key("weight"))
  private static let admitting = SyncConfiguration(activityOnICloud: true)

  private func writeSteps(_ harness: SyncHarness) async throws {
    try await harness.store.write { transaction in _ = try transaction.set(Self.stepsRef, ["value": .int(8042)]) }
  }

  private func storedKinds(_ harness: SyncHarness) async throws -> Set<EntityKind> {
    Set(try await harness.segments().flatMap(\.file.lines).compactMap { line in (try? CanonicalJSON.decode(line)).flatMap { try? ChangeRecord(json: $0) }?.entity })
  }

  @Test("should refuse an activity-class change on an iCloud provider unless the configuration admits it")
  func shouldRefuseActivityByDefault() async throws {
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let harness = try await SyncHarness.started(store: try SyncFixture.open(registry: Self.registry), provider: provider)
    try await writeSteps(harness)
    let pending = try await harness.pendingLines()

    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .syncClassRefused(Self.steps, .activity)? = error else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: error))") }
    let compaction = await #expect(throws: SyncError.self) { try await harness.engine.compact(force: true) }
    guard case .syncClassRefused(Self.steps, .activity)? = compaction else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: compaction))") }

    #expect(provider.callCounts.put == 0)
    #expect(try await harness.pendingLines() == pending)
  }

  @Test("should upload activity-class changes to an iCloud provider when the configuration admits them")
  func shouldUploadAdmittedActivity() async throws {
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let harness = try await SyncHarness.started(store: try SyncFixture.open(registry: Self.registry), provider: provider, configuration: Self.admitting)
    try await harness.writeNotes(1)
    try await writeSteps(harness)

    guard case .uploaded = try await harness.engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }

    #expect(try await storedKinds(harness).isSuperset(of: [SyncFixture.note, Self.steps]))
    #expect(try await harness.pendingLines().isEmpty)
  }

  @Test("should keep refusing health-class changes on an iCloud provider that admits activity")
  func shouldRefuseHealthWhileAdmittingActivity() async throws {
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let harness = try await SyncHarness.started(store: try SyncFixture.open(registry: Self.registry), provider: provider, configuration: Self.admitting)
    try await writeSteps(harness)
    try await harness.store.write { transaction in _ = try transaction.set(Self.weightRef, ["value": .int(72)]) }

    let error = await #expect(throws: SyncError.self) { try await harness.engine.upload() }
    guard case .syncClassRefused(SyncFixture.vital, .health)? = error else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: error))") }

    #expect(provider.callCounts.put == 0)
  }

  @Test("should keep a segment sealed while activity was admitted when it resumes under a configuration that no longer admits it")
  func shouldKeepAnInFlightActivitySegmentAfterTheSettingTurnsOff() async throws {
    let directory = ReplicaTemporaryDirectory()
    let location = StoreLocation.file(directory.database("vault"))
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let keychain = InMemoryKeychain()
    let crashing = try await SyncHarness.started(
      store: try SyncFixture.open(location, registry: Self.registry), provider: provider, keychain: keychain, configuration: Self.admitting, crashAt: .outboxSaved)
    try await writeSteps(crashing)
    _ = await #expect(throws: SyncError.self) { try await crashing.engine.upload() }
    let saved = try #require(try await crashing.savedUpload())

    let refusing = SyncHarness(store: try SyncFixture.open(location, registry: Self.registry), provider: provider, keychain: keychain)
    _ = try await refusing.engine.start()
    let error = await #expect(throws: SyncError.self) { try await refusing.engine.upload() }
    guard case .syncClassRefused(Self.steps, .activity)? = error else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: error))") }
    #expect(provider.callCounts.put == 0)
    #expect(try await refusing.savedUpload() == saved)

    let admitting = SyncHarness(store: try SyncFixture.open(location, registry: Self.registry), provider: provider, keychain: keychain, configuration: Self.admitting)
    _ = try await admitting.engine.start()
    #expect(try await admitting.engine.upload() == .uploaded([saved.point]))
  }

  @Test("should seal a move base with activity-class changes for an iCloud target only when the configuration admits them")
  func shouldHonourTheActivityAdmissionWhenSealingAMoveBase() async throws {
    let target = InMemoryStorageProvider(classPolicy: .iCloud).capabilities
    let refusing = try await SyncHarness.started(store: try SyncFixture.open(registry: Self.registry))
    try await writeSteps(refusing)
    let error = await #expect(throws: SyncError.self) { try await refusing.engine.sealMoveBase(for: target) }
    guard case .syncClassRefused(Self.steps, .activity)? = error else { throw SyncFixtureFailure("expected syncClassRefused, got \(String(describing: error))") }

    let admitting = try await SyncHarness.started(store: try SyncFixture.open(registry: Self.registry), configuration: Self.admitting)
    try await writeSteps(admitting)
    #expect(try await admitting.engine.sealMoveBase(for: target).parts.isEmpty == false)
  }
}
