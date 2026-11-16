import Foundation
import GRDB
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

private func edit(_ generator: inout SeededGenerator, on store: VaultStore) async throws {
  let ref = EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("n\(generator.int(in: 0...5))"))
  let purge = generator.chance(0.1)
  let title = generator.asciiString(maxLength: 40)
  do {
    _ = try await store.write { transaction in purge ? try transaction.purge(ref) : try transaction.set(ref, ["title": .string(title)]) }
  } catch {
    guard case .entityPurged = error else { throw error }
  }
}

/// A storage fault or an injected crash ends one call; anything else fails the property.
private func tolerate(_ body: () async throws(SyncError) -> Void) async throws -> Bool {
  do {
    try await body()
    return true
  } catch {
    switch error {
    case .storage, .corruptState("injected crash"): return false
    default: throw error
    }
  }
}

private struct SyncAdoptPeer {
  let name: String
  let store: VaultStore
  let provider: any StorageProvider
  var harness: SyncHarness
}

private struct SyncAdoptTally {
  var adopted = 0
  var retired = 0
  var crashes = 0
  var foreignDeletes = 0
}

/// Every key a peer deletes outside its current prefix, other than a manifest, must have a fold row in that peer's database at that moment.
private final class SyncDeleteAudit: Sendable {
  private let violations = Mutex<[ObjectKey]>([])
  private let foreign = Mutex(0)

  var found: [ObjectKey] { violations.withLock { $0 } }
  var foreignDeletes: Int { foreign.withLock { $0 } }

  func check(_ keys: [ObjectKey], by store: VaultStore) async {
    for key in keys {
      let owner: ReplicaID?
      switch VaultPath.classify(key) {
      case .segment(let replica, _, _, _), .basePart(let replica, _, _, _, _): owner = replica
      default: owner = nil
      }
      guard let owner, owner != store.replica else { continue }
      foreign.withLock { $0 += 1 }
      let folded =
        (try? await store.read { try Bool.fetchOne($0.database, sql: "SELECT EXISTS (SELECT 1 FROM sync_adoption_fold WHERE object_key = ?)", arguments: [key.rawValue]) }) ?? nil
      if folded != true { violations.withLock { $0.append(key) } }
    }
  }
}

private func runAdoptionProperty(_ generator: inout SeededGenerator, tally: inout SyncAdoptTally) async throws {
  let log = SyncPutLog(wrapping: InMemoryStorageProvider(pageSize: generator.int(in: 2...8)))
  let plan = FaultPlan(transientFailure: 0.04, lostAcknowledgement: 0.1, staleListing: 0.5, partialPage: 0.3, delayedDelete: 0.5, staleOperations: 1...12)
  let faulty = FaultInjectingStorageProvider(wrapping: log, seed: generator.next(), plan: plan)
  let world = SyncCompactWorld(storage: faulty)
  let configuration = SyncConfiguration(
    maximumSegmentLines: generator.int(in: 1...3), compactionAge: .zero, compactionBytes: .max, compactionFiles: .max, compactionInterval: .zero,
    basePartBytes: generator.chance(0.5) ? 600 : BaseCodec.defaultPartPayloadBytes, adoptionDelay: .seconds(generator.int(in: 0...8)),
    adoptionAbandonDelay: SyncDays.duration(10))
  let audit = SyncDeleteAudit()
  var peers: [SyncAdoptPeer] = []
  for index in 0..<generator.int(in: 3...4) {
    let store = try world.openStore()
    let provider = SyncAuditingProvider(wrapping: SyncCompactProvider(wrapping: faulty)) { keys in await audit.check(keys, by: store) }
    let harness = try await world.started(world.harness("peer\(index)", store: store, provider: provider, configuration: configuration), createsKey: index == 0)
    peers.append(SyncAdoptPeer(name: "peer\(index)", store: store, provider: provider, harness: harness))
  }
  var written: Set<Data> = []
  func capture() async throws {
    for peer in peers { written.formUnion(try await peer.store.pendingChanges(limit: Int.max).map(\.line)) }
  }
  /// A reader that has never synced, over storage with no faults, must hold every change any segment ever carried, whatever step the peers are at.
  var referenced: Set<ObjectKey> = []
  var reference = VaultState()
  func expectFreshReaderConverges(after step: Int) async throws {
    let reader = try await world.started(world.harness("reader", store: try world.openStore(), provider: log, configuration: SyncConfiguration(dependencyWaitCalls: 1)))
    _ = try reader.ring.refresh()
    for (key, data) in log.putSegments where referenced.insert(key).inserted {
      for line in try SegmentCodec.open(data, at: key, vault: SyncFixture.vault, keys: { reader.ring.key($0) }).lines {
        reference.apply(try ChangeRecord(json: CanonicalJSON.decode(line)), registry: SyncFixture.registry)
      }
    }
    var withReader = reference
    for line in try await reader.pendingLines() { withReader.apply(try ChangeRecord(json: CanonicalJSON.decode(line)), registry: SyncFixture.registry) }
    let expected = withReader.retained(registry: SyncFixture.registry).digest
    for _ in 0..<8 {
      _ = try await reader.engine.download()
      if try await reader.digest() == expected { return }
    }
    throw SyncFixtureFailure("a fresh reader did not converge after step \(step)")
  }
  func restart(_ index: Int, probe: SyncAdoptProbe = SyncAdoptProbe(), crashAt step: SyncUploadStep? = nil) async throws {
    let peer = peers[index]
    peers[index].harness = world.harness(
      peer.name, store: peer.store, provider: peer.provider, configuration: configuration, crashAt: step, compactionCheckpoint: probe.compaction,
      adoptionCheckpoint: probe.adoption)
    _ = try await peers[index].harness.engine.start()
  }
  var retirements = 0

  for step in 0..<generator.int(in: 10...18) {
    let index = generator.int(in: 0...(peers.count - 1))
    let engine = peers[index].harness.engine
    var touchesStorage = true
    switch generator.int(in: 0...13) {
    case 0...2:
      for _ in 0..<generator.int(in: 1...3) { try await edit(&generator, on: peers[index].store) }
      touchesStorage = false
    case 3:
      _ = try await tolerate { () async throws(SyncError) in _ = try await engine.upload() }
    case 4, 5:
      _ = try await tolerate { () async throws(SyncError) in _ = try await engine.sync() }
    case 6:
      let force = generator.chance(0.6)
      _ = try await tolerate { () async throws(SyncError) in _ = try await engine.compact(force: force) }
    case 7, 8:
      var outcome: SyncAdoptionOutcome?
      _ = try await tolerate { () async throws(SyncError) in outcome = try await engine.adopt() }
      if case .progressed(let adopted, _)? = outcome { tally.adopted += adopted.count }
    case 9 where retirements < 2:
      let target = peers[(index + generator.int(in: 1...(peers.count - 1))) % peers.count].store.replica
      let successor = generator.chance(0.5) ? peers[index].store.replica : nil
      try await peers[index].harness.lifecycle.retire(target, successor: successor)
      retirements += 1
      tally.retired += 1
      touchesStorage = false
    case 10:
      world.clock.set(world.clock.now.addingTimeInterval(Double(generator.int(in: 5...20))))
      touchesStorage = false
    default:
      if generator.chance(0.7) {
        try await restart(index, probe: SyncAdoptProbe(crashAt: generator.int(in: 0...14)))
      } else {
        try await restart(index, crashAt: generator.pick(from: SyncUploadStep.allCases))
      }
      let crashing = peers[index].harness.engine
      if try await !tolerate({ () async throws(SyncError) in _ = try await crashing.adopt() }) { tally.crashes += 1 }
      try await restart(index)
    }
    try await capture()
    if touchesStorage { try await expectFreshReaderConverges(after: step) }
    world.clock.set(world.clock.now.addingTimeInterval(Double(generator.int(in: 0...3))))
  }

  faulty.setFaultsEnabled(false)
  faulty.heal()
  for index in peers.indices { try await restart(index) }
  world.clock.set(world.clock.now.addingTimeInterval(11 * SyncDays.day))
  var settled = false
  for _ in 0..<16 where !settled {
    settled = true
    for peer in peers {
      let engine = peer.harness.engine
      try await capture()
      let (download, upload) = try await engine.sync()
      let compaction = try await engine.compact()
      let adoption = try await engine.adopt()
      if case .progressed(let adopted, _) = adoption { tally.adopted += adopted.count }
      let waiting = download.held.values.contains { reason in
        guard case .incompleteBase = reason else { return true }
        return false
      }
      if !download.applied.isEmpty || upload != .nothingToUpload || waiting || compaction != .notNeeded || adoption != .nothingToAdopt { settled = false }
    }
  }
  guard settled else { throw SyncFixtureFailure("the peers did not settle") }

  try await capture()
  let ring = peers[0].harness.ring
  let uploaded = try SyncAdoptCheck.uploadedLines(log, ring: ring)
  guard written.isSubset(of: uploaded) else { throw SyncFixtureFailure("a change written locally never reached storage") }
  let expected = try SyncAdoptCheck.reference(log, ring: ring)
  tally.foreignDeletes += audit.foreignDeletes
  guard audit.found.isEmpty else { throw SyncFixtureFailure("deleted without a fold row: \(audit.found)") }
  let active = Set(try await peers[0].harness.lifecycle.directory().replicas.filter { $0.state == .active }.map(\.replica))
  for peer in peers {
    guard try await peer.harness.digest() == expected else { throw SyncFixtureFailure("\(peer.name) differs from every change written") }
    guard try await peer.harness.pendingLines().isEmpty else { throw SyncFixtureFailure("\(peer.name) still has pending changes") }
    guard active.contains(peer.store.replica) else { throw SyncFixtureFailure("\(peer.name) is not active") }
    let entries = try await SyncCompactCheck.entries(peer.harness)
    let stored = try await SyncStoredFiles.read(peer.store.replica, in: log)
    for base in entries where base.isCompleteBase && base.isLive {
      guard let found = stored.bases[base.point], found.isComplete, found.parts == base.parts else {
        throw SyncFixtureFailure("\(peer.name) lost a part of its base \(base.point)")
      }
    }
  }
}

@Suite("SyncEngine adoption under faults")
struct SyncAdoptPropertyTests {
  /// Six runs of 10 seeded cases each, so the 60 cases run in parallel.
  @Test(
    "should converge every active replica to every change written through random retirements, adoptions, compactions and crashes on a hostile provider",
    arguments: [0xAD_0B7, 0xAD_0B8, 0xAD_0B9, 0xAD_0BA, 0xAD_0BB, 0xAD_0BC] as [UInt64])
  func shouldConvergeWithAdoption(_ seed: UInt64) async throws {
    var tally = SyncAdoptTally()
    try await forAll(iterations: 10, seed: seed) { generator in
      try await runAdoptionProperty(&generator, tally: &tally)
    }
    #expect(tally.retired > 3 && tally.adopted > 2 && tally.crashes > 4 && tally.foreignDeletes > 4, "\(tally)")
  }
}
