import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private struct SyncSimTally {
  var restores = 0
  var clones = 0
  var reinstalls = 0
  var removals = 0
  var crashes = 0
  /// Adoption calls during the faulty steps that folded, published or deleted something.
  var adoptions = 0
  var wrongClocks = 0
  var freshReaders = 0
  var foreignDeletes = 0
  /// Retired replicas whose prefix holds only a manifest: adoption volunteers only for a prefix with a segment or a base part.
  var strayManifests = 0
  var stalledTails = 0
  /// Replicas with files in storage whose active record never reached it, so no device list could offer to remove them.
  var undeclared = 0
}

private let year: TimeInterval = 365 * SyncDays.day
private let hours: TimeInterval = 2 * 3_600
private let nearOffsets: [TimeInterval] = [0, 0, hours, -hours]
private let wrongOffsets: [TimeInterval] = nearOffsets + [year, -year]

/// A storage fault or an injected crash ends one call; anything else fails the simulation.
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

private func isManifest(_ key: ObjectKey) -> Bool {
  guard case .manifest = VaultPath.classify(key) else { return false }
  return true
}

private enum SyncSimLeftover {
  case manifest
  /// The known stall K17c removes: the successor chain was re-pointed around the adopter whose fact covers the gap, to a replica that holds none of what
  /// that fact covers, so it can never publish the segments after it.
  case tailBeyondFact
  case unexplained
}

private func leftover(_ files: [ObjectKey], of owner: ReplicaID, in directory: ReplicaDirectory) -> SyncSimLeftover {
  var firsts: [Int64] = []
  for key in files {
    switch VaultPath.classify(key) {
    case .manifest: continue
    case .segment(_, let first, _, _): firsts.append(first)
    default: return .unexplained
    }
  }
  guard let first = firsts.min() else { return .manifest }
  let facts = directory.adoptions.filter { $0.adopted == owner }
  let covered = facts.filter { $0.through >= first - 1 }
  guard first > 1, !covered.isEmpty, let chain = activeChain(from: owner, in: directory), !covered.contains(where: { chain.contains($0.adopter) }) else {
    return .unexplained
  }
  return .tailBeyondFact
}

/// Every replica on the successor chain from `start` when it ends at an active replica, else nil.
private func activeChain(from start: ReplicaID, in directory: ReplicaDirectory) -> Set<ReplicaID>? {
  var visited: Set<ReplicaID> = []
  var current = start
  while visited.insert(current).inserted, let entry = directory.entry(for: current) {
    if entry.state == .active { return visited }
    guard let successor = entry.successor else { return nil }
    current = successor
  }
  return nil
}

/// The user confirms the retirement of a replica the device list shows without a device, as Settings offers after a restore or a reinstall.
private func confirm(_ bootstrap: ReplicaBootstrap, on device: SyncSimDevice) async throws {
  switch bootstrap {
  case .claimed(let previous?), .reminted(_, .markerNamesOther(let previous)):
    guard previous != device.replica else { return }
    try await device.harness.lifecycle.retire(previous, successor: device.replica)
  default:
    break
  }
}

/// Time for every retirement to come due, then every device syncs and adopts, still on its faulty view.
private func adoptionRound(_ world: SyncSimWorld, tally: inout SyncSimTally) async throws {
  world.advance(days: 1.5)
  for device in world.devices {
    let engine = device.engine
    _ = try await tolerate { () async throws(SyncError) in _ = try await engine.sync() }
    var outcome: SyncAdoptionOutcome?
    _ = try await tolerate { () async throws(SyncError) in outcome = try await engine.adopt() }
    if case .progressed? = outcome { tally.adoptions += 1 }
  }
}

private func simulate(_ generator: inout SeededGenerator, tally: inout SyncSimTally) async throws {
  let serverTime = generator.chance(0.5)
  let configuration = SyncConfiguration(
    maximumSegmentLines: generator.int(in: 1...3), compactionAge: .zero, compactionBytes: .max, compactionFiles: generator.int(in: 3...8), compactionInterval: .zero,
    basePartBytes: generator.chance(0.5) ? 600 : 1_500, adoptionDelay: SyncDays.duration(generator.int(in: 0...1)), adoptionAbandonDelay: SyncDays.duration(4))
  let world = try SyncSimWorld(seed: generator.next(), serverTime: serverTime, configuration: configuration)
  let plan = FaultPlan(transientFailure: 0.03, lostAcknowledgement: 0.08, staleListing: 0.4, partialPage: 0.3, delayedDelete: 0.4, staleOperations: 1...10)
  var named = 0
  func faults(_ generator: inout SeededGenerator) -> SyncSimFaults {
    SyncSimFaults(plan: plan, lag: 0.15, lagListings: 1...4, lagged: SyncSimFaults.isReplicaFile, seed: generator.next())
  }
  for _ in 0..<generator.int(in: 3...4) {
    named += 1
    try await world.addDevice("d\(named)", faults: faults(&generator))
  }
  var snapshots: [String: URL] = [:]

  for step in 0..<generator.int(in: 14...22) {
    let device = generator.pick(from: world.devices)
    let engine = device.engine
    var touchesStorage = true
    let action = generator.int(in: 0...20)
    world.note("\(step): \(device.name) as \(device.replica) action \(action)")
    switch action {
    case 0...3:
      try await world.write(generator.int(in: 1...3), on: device)
      if generator.chance(0.5) { try await world.contest(generator.int(in: 0...2), on: device, purge: generator.chance(0.1)) }
      touchesStorage = false
    case 4...6:
      _ = try await tolerate { () async throws(SyncError) in _ = try await engine.sync() }
    case 7:
      _ = try await tolerate { () async throws(SyncError) in _ = try await engine.upload() }
    case 8:
      _ = try await tolerate { () async throws(SyncError) in _ = try await engine.download() }
    case 9:
      let force = generator.chance(0.6)
      _ = try await tolerate { () async throws(SyncError) in _ = try await engine.compact(force: force) }
    case 10, 11:
      try await adoptionRound(world, tally: &tally)
    case 12:
      snapshots[device.name] = try world.snapshot(device)
      touchesStorage = false
    case 13:
      guard let snapshot = snapshots[device.name] else {
        snapshots[device.name] = try world.snapshot(device)
        continue
      }
      let bootstrap = try await world.restore(device, from: snapshot)
      if generator.chance(0.7) { try await confirm(bootstrap, on: device) }
      tally.restores += 1
    case 14 where world.devices.count < 4:
      named += 1
      try await world.clone(device, as: "d\(named)", faults: faults(&generator))
      tally.clones += 1
    case 15:
      let old = try await world.reinstall(device)
      if generator.chance(0.7) { try await device.harness.lifecycle.retire(old, successor: device.replica) }
      let reinstalled = device.engine
      _ = try await tolerate { () async throws(SyncError) in _ = try await reinstalled.sync() }
      tally.reinstalls += 1
    case 16 where world.devices.count > 2:
      let replica = device.replica
      try await world.remove(device)
      let remover = generator.pick(from: world.devices)
      if generator.chance(0.7) { try await remover.harness.lifecycle.retire(replica) }
      let removing = remover.engine
      _ = try await tolerate { () async throws(SyncError) in _ = try await removing.sync() }
      tally.removals += 1
    case 17:
      world.advance(days: Double(generator.int(in: 2...8)) / 2)
      touchesStorage = false
    case 18:
      device.offset.set(generator.pick(from: serverTime ? wrongOffsets : nearOffsets))
      if abs(device.offset.value) > hours { tally.wrongClocks += 1 }
      touchesStorage = false
    default:
      let crash: SyncSimCrash = generator.chance(0.5) ? .checkpoint(generator.int(in: 0...6)) : .upload(generator.pick(from: SyncUploadStep.allCases))
      try await world.write(1, on: device)
      try await confirm(try await world.restart(device, crash: crash), on: device)
      let crashing = device.engine
      let call = generator.int(in: 0...2)
      let finished = try await tolerate { () async throws(SyncError) in
        switch call {
        case 0: _ = try await crashing.sync()
        case 1: _ = try await crashing.compact(force: true)
        default: _ = try await crashing.adopt()
        }
      }
      if !finished { tally.crashes += 1 }
      try await confirm(try await world.restart(device), on: device)
    }
    world.note("   now \(world.devices.map { "\($0.name)=\($0.replica)" })")
    if touchesStorage {
      try await world.expectFreshReaderConverges("step \(step)")
      tally.freshReaders += 1
    }
    world.clock.set(world.clock.now.addingTimeInterval(Double(generator.int(in: 0...30))))
  }

  try await adoptionRound(world, tally: &tally)
  try await world.expectFreshReaderConverges("after the last round on a hostile provider")
  for _ in 0..<4 {
    world.advance(days: 6)
    try await world.settle()
    let directory = try await world.devices[0].harness.lifecycle.directory()
    let live = Set(world.devices.map(\.replica))
    var retired = 0
    for orphan in directory.replicas where orphan.state == .active && !live.contains(orphan.replica) {
      try await world.devices[0].harness.lifecycle.retire(orphan.replica)
      retired += 1
    }
    for undeclared in try await world.leftovers().keys where directory.entry(for: undeclared) == nil {
      try await world.devices[0].harness.lifecycle.retire(undeclared)
      tally.undeclared += 1
      retired += 1
    }
    if retired == 0, try await world.leftovers().values.joined().allSatisfy(isManifest) { break }
  }
  try await world.settle()
  try await world.verify("settled")
  let final = try await world.devices[0].harness.lifecycle.directory()
  for (owner, files) in try await world.leftovers() {
    switch leftover(files, of: owner, in: final) {
    case .manifest: tally.strayManifests += 1
    case .tailBeyondFact: tally.stalledTails += 1
    case .unexplained:
      throw SyncFixtureFailure(
        "files of a retired replica were never adopted: \(owner) \(String(describing: final.entry(for: owner))): \(files.map(\.rawValue)); facts \(final.adoptions); trace \(world.trace)"
      )
    }
  }
  tally.foreignDeletes += world.audit.foreignDeletes
}

@Suite("Sync simulation: seeded replica lifecycles on a hostile local folder")
struct SyncSimulationPropertyTests {
  /// Each seed runs its cases in turn and the seeds run in parallel; `SHADOW_SYNC_SIMULATION_SCALE` multiplies the cases for a nightly run.
  @Test(
    "should keep every change and converge every replica through random writes, syncs, compactions, adoptions, restores, clones, reinstalls, removals, crashes, clock jumps and stale listings",
    arguments: [0x51_0001, 0x51_0002, 0x51_0003, 0x51_0004] as [UInt64])
  func shouldConvergeThroughLifecycles(_ seed: UInt64) async throws {
    var tally = SyncSimTally()
    try await forAll(iterations: SyncSimulationBudget.cases(5), seed: seed) { generator in
      try await simulate(&generator, tally: &tally)
    }
    #expect(tally.restores + tally.clones + tally.reinstalls + tally.removals > 2 && tally.crashes > 0 && tally.freshReaders > 20, "\(tally)")
    #expect(tally.foreignDeletes > 0 && tally.adoptions > 0, "\(tally)")
  }

  @Test("should replay the one seeded case a failure named", .enabled(if: SyncSimulationBudget.replay != nil))
  func shouldReplaySeed() async throws {
    var tally = SyncSimTally()
    try await replay(seed: SyncSimulationBudget.replay ?? 0) { generator in try await simulate(&generator, tally: &tally) }
  }
}
