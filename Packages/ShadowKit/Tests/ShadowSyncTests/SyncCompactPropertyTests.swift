import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private enum SyncPropertyEdit {
  case set(EntityRef, String)
  case purge(EntityRef)
  case append(EntityRef, String)
  case revise(EntityRef, String)

  static func make(_ generator: inout SeededGenerator) -> SyncPropertyEdit {
    let text = generator.asciiString(maxLength: 24)
    switch generator.int(in: 0...9) {
    case 0...4: return .set(ref(SyncFixture.note, "n", generator.int(in: 0...4)), text)
    case 5: return .purge(ref(SyncFixture.note, "n", generator.int(in: 0...4)))
    case 6, 7: return .append(ref(SyncFixture.message, "m", Int(truncatingIfNeeded: generator.next() >> 1)), text)
    default: return generator.chance(0.15) ? .purge(ref(SyncFixture.draft, "d", generator.int(in: 0...2))) : .revise(ref(SyncFixture.draft, "d", generator.int(in: 0...2)), text)
    }
  }

  private static func ref(_ kind: EntityKind, _ prefix: String, _ index: Int) -> EntityRef {
    EntityRef(kind: kind, key: ReplicaFixture.key("\(prefix)\(index)"))
  }

  func write(to store: VaultStore) async throws {
    do {
      try await store.write { transaction in
        switch self {
        case .set(let ref, let text): _ = try transaction.set(ref, ["title": .string(text)])
        case .purge(let ref): _ = try transaction.purge(ref)
        case .append(let ref, let text): _ = try transaction.append(ref, item: ["text": .string(text)])
        case .revise(let ref, let text): _ = try transaction.revise(ref, body: .string(text))
        }
      }
    } catch {
      guard case .entityPurged = error else { throw error }
    }
  }
}

/// A storage fault or an injected crash ends one call; anything else fails the property.
private func tolerate(_ body: () async throws(SyncError) -> Void) async throws {
  do {
    try await body()
  } catch {
    switch error {
    case .storage, .corruptState("injected crash"): return
    default: throw error
    }
  }
}

private struct SyncPropertyPeer {
  let name: String
  let store: VaultStore
  let provider: SyncCompactProvider
  let replica: ReplicaID
  var harness: SyncHarness
}

private struct SyncPropertyTally {
  var bases = 0
  var deleted = 0
  var crashes = 0
}

private func runCompactionProperty(_ generator: inout SeededGenerator, tally: inout SyncPropertyTally) async throws {
  let inner = InMemoryStorageProvider(pageSize: generator.int(in: 2...8))
  let plan = FaultPlan(transientFailure: 0.05, lostAcknowledgement: 0.1, staleListing: 0.5, partialPage: 0.3, delayedDelete: 0.5, staleOperations: 1...20)
  let faulty = FaultInjectingStorageProvider(wrapping: inner, seed: generator.next(), plan: plan)
  let world = SyncCompactWorld(storage: faulty)
  let configuration = SyncConfiguration(
    maximumSegmentLines: generator.int(in: 1...3), uploadPassBytes: generator.chance(0.5) ? 600 : nil, compactionAge: .zero, compactionBytes: .max, compactionFiles: .max,
    compactionInterval: .zero, basePartBytes: generator.chance(0.5) ? 1_000 : BaseCodec.defaultPartPayloadBytes)
  let registry = SyncFixture.richRegistry
  var peers: [SyncPropertyPeer] = []
  for index in 0..<3 {
    let store = try world.openStore(registry: registry)
    let provider = SyncCompactProvider(wrapping: faulty)
    let harness = try await world.started(world.harness("peer\(index)", store: store, provider: provider, configuration: configuration), createsKey: index == 0)
    peers.append(SyncPropertyPeer(name: "peer\(index)", store: store, provider: provider, replica: store.replica, harness: harness))
  }
  var lines: Set<Data> = []
  func capture() async throws {
    for peer in peers { lines.formUnion(try await peer.store.pendingChanges(limit: Int.max).map(\.line)) }
  }
  func restart(_ index: Int, crashAt step: SyncUploadStep? = nil, probe: SyncCompactionProbe = SyncCompactionProbe()) async throws {
    let peer = peers[index]
    peers[index].harness = world.harness(peer.name, store: peer.store, provider: peer.provider, configuration: configuration, crashAt: step, probe: probe)
    _ = try await peers[index].harness.engine.start()
    try await capture()
  }

  try await capture()
  for _ in 0..<generator.int(in: 10...24) {
    let index = generator.int(in: 0...2)
    let engine = peers[index].harness.engine
    switch generator.int(in: 0...12) {
    case 0...2:
      for _ in 0..<generator.int(in: 1...3) { try await SyncPropertyEdit.make(&generator).write(to: peers[index].store) }
    case 3, 4:
      try await tolerate { () async throws(SyncError) in _ = try await engine.upload() }
    case 5, 6:
      try await tolerate { () async throws(SyncError) in _ = try await engine.download() }
    case 7, 8:
      let force = generator.chance(0.7)
      var outcome: SyncCompactionOutcome?
      try await tolerate { () async throws(SyncError) in outcome = try await engine.compact(force: force) }
      if case .compacted? = outcome { tally.bases += 1 }
    case 9:
      try await tolerate { () async throws(SyncError) in _ = try await engine.sync() }
    default:
      if generator.chance(0.5) {
        try await restart(index, probe: SyncCompactionProbe(crashAt: generator.int(in: 0...12)))
      } else {
        try await restart(index, crashAt: generator.pick(from: SyncUploadStep.allCases))
      }
      let crashing = peers[index].harness.engine
      let force = generator.chance(0.7)
      var crashed = true
      try await tolerate { () async throws(SyncError) in
        _ = try await crashing.compact(force: force)
        crashed = false
      }
      if crashed { tally.crashes += 1 }
      try await restart(index)
    }
    try await capture()
    world.clock.set(world.clock.now.addingTimeInterval(Double(generator.int(in: 0...5))))
  }

  faulty.setFaultsEnabled(false)
  faulty.heal()
  for index in peers.indices { try await restart(index) }
  func settle() async throws {
    for _ in 0..<20 {
      var changed = false
      for peer in peers {
        try await capture()
        let (download, upload) = try await peer.harness.engine.sync()
        let waiting = download.held.values.contains { reason in
          guard case .incompleteBase = reason else { return true }
          return false
        }
        if !download.applied.isEmpty || upload != .nothingToUpload || waiting { changed = true }
      }
      if !changed { return }
    }
    throw SyncFixtureFailure("the peers did not settle")
  }
  try await settle()
  for peer in peers { _ = try await peer.harness.engine.compact() }
  try await settle()

  let expected = try SyncCompactCheck.reference(lines, registry: registry)
  tally.deleted += peers.map(\.provider.deleted.count).reduce(0, +)
  for peer in peers {
    guard try await peer.harness.digest() == expected else { throw SyncFixtureFailure("\(peer.name) differs from every change written") }
    guard try await peer.harness.pendingLines().isEmpty else { throw SyncFixtureFailure("\(peer.name) still has pending changes") }
    guard peer.store.replica == peer.replica else { throw SyncFixtureFailure("\(peer.name) was re-minted") }
    let strangers = try await SyncCompactCheck.ownDeletes(peer.provider.deleted, by: peer.store)
    guard strangers.isEmpty else { throw SyncFixtureFailure("\(peer.name) deleted names outside its history: \(strangers)") }
    let entries = try await SyncCompactCheck.entries(peer.harness)
    let stored = try await SyncStoredFiles.read(peer.replica, in: inner)
    for base in entries where base.isCompleteBase && base.isLive {
      guard let found = stored.bases[base.point], found.isComplete, found.parts == base.parts else {
        throw SyncFixtureFailure("\(peer.name) lost a part of its base \(base.point)")
      }
    }
    let liveSegments = Set(entries.filter { !$0.isBase && $0.isLive }.map(\.point))
    guard liveSegments == stored.segments else {
      throw SyncFixtureFailure("\(peer.name)'s live segments differ from storage: \(liveSegments.symmetricDifference(stored.segments))")
    }
  }
}

@Suite("SyncEngine compaction under faults")
struct SyncCompactPropertyTests {
  @Test("should converge three replicas to every change written through random uploads, downloads, compactions and crashes on a hostile provider")
  func shouldConvergeWithCompaction() async throws {
    var tally = SyncPropertyTally()
    try await forAll(iterations: 60, seed: 0xC0_4AC7) { generator in
      try await runCompactionProperty(&generator, tally: &tally)
    }
    #expect(tally.bases > 20 && tally.deleted > 40 && tally.crashes > 30, "\(tally)")
  }
}
