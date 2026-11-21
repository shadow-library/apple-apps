import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Job engine: the vault's worker", TestTimeLimit.quick)
struct JobEngineWorkerTests {
  @Test func shouldNameThisReplicaOrNoneAsTheWorkerKeepingSinceWhenNamedAgain() async throws {
    let world = try await JobEngineWorld()
    let engine = try world.engine()
    let here = world.store.replica
    #expect(try await engine.worker() == .none)
    let since = world.clock.instant
    let named = try await engine.designateWorker(.thisReplica)
    #expect(named == .named(JobDevice(replica: here, name: nil, isHere: true)) && named.isHere)
    world.clock.advance(60)
    #expect(try await engine.designateWorker(.thisReplica) == named)
    #expect(try await world.store.read { transaction in try WorkerRecords.read(in: transaction) }.record?.since == since)
    #expect(try await engine.worker() == named)
    #expect(try await engine.designateWorker(.none) == .none)
    #expect(try await world.store.read { transaction in try WorkerRecords.read(in: transaction) }.record?.since == world.clock.instant)
  }

  @Test func shouldFollowARetiredWorkerToItsSuccessorAndObserveTheChange() async throws {
    let world = try await JobEngineWorld()
    let engine = try world.engine()
    let (mac, reinstalled) = (JobWorld.replicas[0], JobWorld.replicas[1])
    let since = world.clock.instant
    var workers = engine.observeWorker().makeAsyncIterator()
    #expect(try await workers.next() == VaultWorker.none)
    try await world.store.write { transaction in
      try ReplicaDirectory.declareActive(mac, name: "Studio Mac", platform: "macOS", createdMillis: 1, in: &transaction)
      _ = try WorkerRecords.designate(mac, at: since, in: &transaction)
    }
    #expect(try await workers.next() == .named(JobDevice(replica: mac, name: "Studio Mac", isHere: false)))
    try await world.store.write { transaction in
      try ReplicaDirectory.declareActive(reinstalled, name: "Studio Mac", platform: "macOS", createdMillis: 2, in: &transaction)
      try ReplicaDirectory.retire(mac, successor: reinstalled, in: &transaction)
    }
    #expect(try await engine.worker() == .named(JobDevice(replica: reinstalled, name: "Studio Mac", isHere: false)))
    try await world.store.write { transaction in try ReplicaDirectory.retire(reinstalled, successor: nil, in: &transaction) }
    #expect(try await engine.worker() == .retired(reinstalled))
  }
}
