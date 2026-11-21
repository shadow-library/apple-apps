import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowJobs

@Suite("WorkerRecords", TestTimeLimit.quick)
struct WorkerRecordsTests {
  private static func designate(_ replica: ReplicaID?, at seconds: Int64, in store: VaultStore) async throws -> WorkerRecord {
    try await store.write { transaction in try WorkerRecords.designate(replica, at: JobFixture.instant(seconds), in: &transaction) }
  }

  private static func read(_ store: VaultStore) async throws -> WorkerReading {
    try await store.read { transaction in try WorkerRecords.read(in: transaction) }
  }

  @Test func shouldDeclareTheWorkerKindApartFromTheJobEntitiesUnderTheShadowJobsDomain() {
    #expect(JobSchema.workerEntities.map(\.kind.rawValue) == ["jobs_worker"])
    #expect(JobSchema.workerEntities.first?.shape == .record(fields: ["replica": .register, "since": .register]))
    #expect(JobSchema.workerEntities.allSatisfy { $0.syncClass == .general })
    #expect(!JobSchema.entities.map(\.kind).contains(JobSchema.workerKind))
    let key = EntityKey.natural(scope: "com.shadow.library.shadowjobs.worker", kind: JobSchema.workerKind, components: [])
    #expect(WorkerRecords.ref == EntityRef(kind: JobSchema.workerKind, key: key))
  }

  @Test func shouldReadNoWorkerUntilOneIsNamedAndKeepSinceWhenTheSameReplicaIsNamedAgain() async throws {
    let store = try JobFixture.open()
    let mac = JobFixture.replica(1)
    #expect(try await Self.read(store) == .absent)
    let named = try await Self.designate(mac, at: 10, in: store)
    #expect(named == WorkerRecord(replica: mac, since: JobFixture.instant(10)))
    let pending = try await store.pendingChanges(limit: Int.max).count
    #expect(try await Self.designate(mac, at: 20, in: store) == named)
    #expect(try await store.pendingChanges(limit: Int.max).count == pending)
    #expect(try await Self.read(store) == .readable(named))
    let cleared = try await Self.designate(nil, at: 30, in: store)
    #expect(try await Self.read(store) == .readable(cleared))
    #expect(cleared.replica == nil && cleared.since == JobFixture.instant(30))
  }

  @Test func shouldConvergeOnTheLaterDesignationWhenTwoReplicasNameAWorkerConcurrently() async throws {
    let firstClock = DeviceClock()
    let secondClock = DeviceClock()
    secondClock.advance(1)
    let stores = [try JobFixture.open(clock: firstClock), try JobFixture.open(clock: secondClock)]
    _ = try await Self.designate(JobFixture.replica(1), at: 0, in: stores[0])
    let later = try await Self.designate(JobFixture.replica(2), at: 1, in: stores[1])
    try await JobFixture.exchange(stores)
    for store in stores { #expect(try await Self.read(store) == .readable(later)) }

    firstClock.advance(5)
    secondClock.advance(2)
    let cleared = try await Self.designate(nil, at: 5, in: stores[0])
    _ = try await Self.designate(JobFixture.replica(3), at: 3, in: stores[1])
    try await JobFixture.exchange(stores)
    for store in stores { #expect(try await Self.read(store) == .readable(cleared)) }
  }

  @Test func shouldReadAMalformedDesignationAsUnreadableAndOverwriteItWithTheNextOne() async throws {
    let store = try JobFixture.open()
    _ = try await store.write { transaction in try transaction.set(WorkerRecords.ref, ["replica": 7, "since": ["millis": 1, "clock": "device"]]) }
    #expect(try await Self.read(store) == .unreadable("replica is neither a replica id nor null"))
    _ = try await store.write { transaction in try transaction.set(WorkerRecords.ref, ["replica": .null, "since": ["millis": 1, "clock": "sundial"]]) }
    #expect(try await Self.read(store) == .unreadable("since.clock is not a known value"))
    let named = try await Self.designate(JobFixture.replica(1), at: 2, in: store)
    #expect(try await Self.read(store) == .readable(named))
  }

  @Test func shouldRefuseToNameAWorkerInAVaultWhoseRegistryLeavesTheKindOut() async throws {
    let store = try VaultStore.open(.inMemory, registry: SchemaRegistry(version: 1, entities: JobSchema.entities))
    await #expect(throws: StoreError.self) { try await Self.designate(JobFixture.replica(1), at: 0, in: store) }
  }
}
