import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

private let sketch = ReplicaFixture.kind("sketch")

private let newer = SyncKernelSchema.registry(
  version: 4,
  adding: [
    EntitySchema(kind: SyncFixture.note, shape: .record(fields: ["title": .register, "mood": .register]), syncClass: .general),
    EntitySchema(kind: SyncFixture.vital, shape: .record(fields: ["value": .register]), syncClass: .health),
    EntitySchema(kind: sketch, shape: .record(fields: ["shape": .register]), syncClass: .general),
  ])

enum SyncSimHidden: CaseIterable, Sendable {
  case basePart
  case segment
}

private let smallParts = SyncConfiguration(
  maximumSegmentLines: 2, compactionAge: .zero, compactionBytes: .max, compactionFiles: .max, compactionInterval: .zero, basePartBytes: 600,
  adoptionDelay: SyncDays.duration(2), adoptionAbandonDelay: SyncDays.duration(4))

private func baseLines(of device: SyncSimDevice, in world: SyncSimWorld) async throws -> Set<Data> {
  Set(try await SyncAdoptCheck.baseLines(of: device.replica, in: world.log, ring: world.observer))
}

private func tolerate(_ body: () async throws(SyncError) -> Void) async throws {
  do {
    try await body()
  } catch {
    guard case .corruptState("injected crash") = error else { throw error }
  }
}

@Suite("Sync simulation: newer schemas and stale listings")
struct SyncSimulationStorageTests {
  @Test("should leave an existing key out of exactly the next listings that cover it, keep serving reads of it, and forget it once deleted")
  func shouldHideExistingKeyForListings() async throws {
    let inner = InMemoryStorageProvider()
    let lagging = LaggingListingStorageProvider(wrapping: inner)
    let key = try #require(ObjectKey("replicas/a/manifest"))
    let other = try #require(ObjectKey("vault.json"))
    for object in [key, other] { _ = try await inner.put(object, data: Data("x".utf8), condition: .overwrite) }
    #expect(try await lagging.listAll(prefix: "").map(\.key) == [key, other])

    lagging.hide(key, listings: 2)

    #expect(try await lagging.listAll(prefix: "vault").map(\.key) == [other])
    #expect(try await lagging.listAll(prefix: "").map(\.key) == [other])
    #expect(try await lagging.get(key) == Data("x".utf8))
    #expect(try await lagging.listAll(prefix: "replicas/").map(\.key) == [])
    #expect(try await lagging.listAll(prefix: "").map(\.key) == [key, other])
    lagging.hide(key, listings: 5)
    try await lagging.delete([key])
    _ = try await inner.put(key, data: Data("y".utf8), condition: .overwrite)
    #expect(try await lagging.listAll(prefix: "").map(\.key) == [key, other])
  }

  @Test("should hide each eligible object at random for a drawn number of listings, never one that is not eligible")
  func shouldHideAtRandom() async throws {
    let inner = InMemoryStorageProvider()
    let eligible = try #require(ObjectKey("replicas/a/manifest"))
    let kept = try #require(ObjectKey("vault.json"))
    for object in [eligible, kept] { _ = try await inner.put(object, data: Data("x".utf8), condition: .overwrite) }
    let lagging = LaggingListingStorageProvider(wrapping: inner, seed: 7, probability: 0.5, listings: 1...3) { $0 == eligible }

    var shown = 0
    for _ in 0..<40 {
      let keys = try await lagging.listAll(prefix: "").map(\.key)
      #expect(keys.contains(kept))
      if keys.contains(eligible) { shown += 1 }
    }

    #expect(lagging.hidings > 3 && shown > 3 && shown < 37)
    lagging.setEnabled(false)
    lagging.heal()
    #expect(try await lagging.listAll(prefix: "").map(\.key) == [eligible, kept])
  }

  @Test("should keep a newer app's unknown kinds, fields and opaque lines through adoption by an older app, a second adoption and a recompaction, for a newer reader")
  func shouldCarryNewerSchemaContent() async throws {
    let world = try SyncSimWorld()
    let first = try await world.addDevice("first")
    let second = try await world.addDevice("second")
    let future = try await world.addDevice("future", registry: newer)
    try await world.write(2, on: first)
    _ = try await future.store.write { transaction in
      _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("future-note")), ["title": .string("kept"), "mood": .string("bright")])
      _ = try transaction.set(EntityRef(kind: sketch, key: ReplicaFixture.key("future-sketch")), ["shape": .string("spiral")])
    }
    let opaque = CanonicalJSON.encode(.object(["format": .string("from a later app")]))
    let planted = ReplicaID(UUID.v7())
    _ = try await SyncPlant.segment([opaque], replica: planted, key: try #require(first.harness.ring.writingKey()), in: world.log)
    try await world.settle()
    let sketchLine = try #require(try world.putLines().first { (try? ChangeRecord(json: CanonicalJSON.decode($0)))?.entity == sketch })
    let futureID = future.replica
    try await world.remove(future)
    try await first.harness.lifecycle.retire(futureID, successor: first.replica)
    try await first.harness.lifecycle.retire(planted, successor: first.replica)
    world.advance(days: 5)
    try await world.settle()

    #expect(try await SyncAdoptCheck.stored(under: futureID, in: world.log).isEmpty)
    let folded = try await baseLines(of: first, in: world)
    #expect(folded.contains(sketchLine) && folded.contains(opaque))
    let firstID = first.replica
    try await world.remove(first)
    try await second.harness.lifecycle.retire(firstID, successor: second.replica)
    world.advance(days: 5)
    try await world.settle()
    try await world.write(2, on: second)
    _ = try await second.engine.sync()
    #expect(try await second.engine.compact(force: true) != .postponed)
    try await world.settle()

    let carried = try await baseLines(of: second, in: world)
    #expect(carried.contains(sketchLine) && carried.contains(opaque))
    #expect(try await SyncAdoptCheck.stored(under: firstID, in: world.log).isEmpty)
    try await world.verify("after two adoptions by older apps")
    let (reader, _) = try await world.freshReader("newer reader", registry: newer)
    let note = try await reader.store.read { try $0.state(of: EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("future-note"))) }
    guard case .record(let record)? = note else { throw SyncFixtureFailure("the newer reader lacks the note") }
    #expect(record[field: "mood"]?.value == .string("bright"))
    #expect(try await reader.store.read { try $0.state(of: EntityRef(kind: sketch, key: ReplicaFixture.key("future-sketch"))) } != nil)
    #expect(try await reader.store.loadState(.vault).opaqueLines.contains(opaque))
  }

  @Test("should lose nothing and delete only by the rules while listings hide existing segments and base parts during folds and compactions")
  func shouldConvergeUnderStaleListings() async throws {
    let world = try SyncSimWorld()
    var devices: [SyncSimDevice] = []
    for (index, name) in ["phone", "mac", "tablet", "lost"].enumerated() {
      devices.append(
        try await world.addDevice(name, faults: SyncSimFaults(lag: 0.3, lagListings: 1...5, lagged: SyncSimFaults.isReplicaFile, seed: 0x57A1E + UInt64(index))))
    }
    let lost = devices[3]
    for round in 0..<10 {
      for device in world.devices {
        try await world.write(2, on: device)
        try await world.contest(round % 2, on: device)
        _ = try await device.engine.sync()
        _ = try await device.engine.compact(force: true)
        _ = try await device.engine.adopt()
      }
      if round == 2 {
        let lostID = lost.replica
        try await world.remove(lost)
        try await devices[1].harness.lifecycle.retire(lostID, successor: devices[1].replica)
      }
      world.advance(days: 1)
      try await world.expectFreshReaderConverges("round \(round)")
    }
    #expect(devices.map(\.lag.hidings).reduce(0, +) > 40)
    world.advance(days: 10)
    try await world.settle()
    try await world.verify("listings caught up")
    #expect(world.audit.foreignDeletes > 0 && world.audit.ownDeletes > 0)
  }

  @Test("should delete nothing of an adopted replica while the adopter's own base does not list, and finish once it does")
  func shouldWaitForOwnBaseToList() async throws {
    let target = SyncSimTarget()
    let world = try SyncSimWorld()
    let adopter = try await world.addDevice("adopter", faults: SyncSimFaults(lag: 1, lagListings: 1_000...1_000, lagged: target.isBasePart))
    target.set(adopter.replica)
    let lost = try await world.addDevice("lost")
    try await world.write(3, on: lost)
    try await world.write(3, on: adopter)
    try await world.settle()
    let lostID = lost.replica
    try await world.remove(lost)
    try await adopter.harness.lifecycle.retire(lostID, successor: adopter.replica)
    world.advance(days: 5)
    adopter.lag.setEnabled(true)
    let before = try await SyncAdoptCheck.stored(under: lostID, in: world.log)

    for _ in 0..<4 {
      let outcome = try await adopter.engine.adopt()
      #expect(outcome == .progressed(adopted: [], waiting: [lostID]))
      world.advance(days: 10)
    }

    #expect(try await SyncAdoptCheck.stored(under: lostID, in: world.log) == before)
    try await world.expectFreshReaderConverges("own base unlisted")
    adopter.heal()
    #expect(try await adopter.engine.adopt() == .progressed(adopted: [lostID], waiting: []))
    try await world.settle()
    try await world.verify("own base listed")
  }

  @Test("should finish an adoption whose forced compaction stopped after announcing its base, without another local write")
  func shouldFinishAdoptionAfterAnnouncedBase() async throws {
    let world = try SyncSimWorld()
    let adopter = try await world.addDevice("adopter")
    let lost = try await world.addDevice("lost")
    try await world.write(3, on: lost)
    try await world.write(3, on: adopter)
    try await world.settle()
    let lostID = lost.replica
    try await world.remove(lost)
    try await adopter.harness.lifecycle.retire(lostID, successor: adopter.replica)
    world.advance(days: 5)
    try await world.restart(adopter, crash: .every(.compaction(.announced)))
    let crashing = adopter.engine
    try await tolerate { () async throws(SyncError) in _ = try await crashing.adopt() }
    try await world.restart(adopter)

    var outcomes: [SyncAdoptionOutcome] = []
    for _ in 0..<6 {
      outcomes.append(try await adopter.engine.adopt())
      if outcomes.last == .nothingToAdopt { break }
      world.advance(days: 5)
    }

    #expect(outcomes.contains(.progressed(adopted: [lostID], waiting: [])), "\(outcomes)")
    #expect(try await SyncAdoptCheck.stored(under: lostID, in: world.log).isEmpty)
    try await world.settle()
    try await world.verify("adopted after the stopped compaction")
  }

  @Test(
    "should keep every sibling of a base part and every segment past the published head while a listing hides one file during the fold, and adopt it in a later pass",
    arguments: SyncSimHidden.allCases)
  func shouldAdoptFileHiddenDuringFold(_ hidden: SyncSimHidden) async throws {
    let world = try SyncSimWorld(configuration: smallParts)
    let adopter = try await world.addDevice("adopter")
    let lost = try await world.addDevice("lost")
    try await world.write(12, on: lost)
    _ = try await lost.engine.upload()
    #expect(try await lost.engine.compact(force: true) != .postponed)
    try await world.write(6, on: lost)
    try await world.settle()
    let lostID = lost.replica
    let files = try await SyncStoredFiles.read(lostID, in: world.log)
    let base = try #require(files.bases.values.first)
    let segments = files.segments.filter { $0.last > base.point.last }.sorted { $0.last < $1.last }
    try #require(base.parts >= 3 && segments.count >= 3)
    let key: ObjectKey
    switch hidden {
    case .basePart: key = VaultPath.basePart(lostID, upTo: base.point.last, tag: base.point.tag, part: 2, parts: base.parts)
    case .segment:
      let middle = segments[1]
      key = VaultPath.segment(lostID, first: segments[0].last + 1, last: middle.last, tag: middle.tag)
    }
    try await world.remove(lost)
    try await adopter.harness.lifecycle.retire(lostID, successor: adopter.replica)
    world.advance(days: 3)
    adopter.lag.hide(key, listings: 2)

    var outcomes: [SyncAdoptionOutcome] = []
    for call in 0..<6 {
      outcomes.append(try await adopter.engine.adopt())
      try await world.expectFreshReaderConverges("after adoption call \(call)")
      #expect(world.audit.violations.isEmpty, "after adoption call \(call)")
      if outcomes.last == .nothingToAdopt { break }
      world.advance(days: 1)
    }

    #expect(adopter.lag.omissions > 0)
    #expect(outcomes.first == .progressed(adopted: [], waiting: [lostID]))
    #expect(outcomes.contains(.progressed(adopted: [lostID], waiting: [])), "\(outcomes)")
    #expect(try await SyncAdoptCheck.stored(under: lostID, in: world.log).isEmpty)
    try await world.settle()
    try await world.verify("the hidden file adopted")
  }

  @Test("should remove the prefix of a retired replica that holds only its manifest once it has listed so for the abandon delay, and not before")
  func shouldRemoveStrayManifest() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    try await world.settle()
    let ghost = world.minter.next()
    let manifest = ReplicaManifest(
      replica: ghost, deviceName: "Ghost", platform: "iOS", appVersion: "1.0", schema: 3, head: nil, base: nil, applied: [:], updatedMillis: 0)
    let sealed = try ReplicaManifestCodec.seal(manifest, vault: SyncFixture.vault, with: try #require(phone.harness.ring.writingKey()))
    _ = try await world.log.put(sealed.key, data: sealed.data, condition: .overwrite)
    try await phone.harness.lifecycle.retire(ghost)

    world.advance(days: 3)
    try await world.settle()
    #expect(try await SyncAdoptCheck.stored(under: ghost, in: world.log) == [VaultPath.manifest(ghost)])

    world.advance(days: 3)
    try await world.settle()
    #expect(try await SyncAdoptCheck.stored(under: ghost, in: world.log) == [VaultPath.manifest(ghost)])

    world.advance(days: 2)
    try await world.settle()
    #expect(try await SyncAdoptCheck.stored(under: ghost, in: world.log).isEmpty)
    try await world.verify("the stray manifest removed")
  }

  @Test(
    "should neither delete the manifest nor report adopted while a listing hides a retired replica's segments, until they list or it has shown only the manifest for the abandon delay",
    arguments: [false, true])
  func shouldWaitWhileSegmentsAreHidden(_ hiddenForLong: Bool) async throws {
    let world = try SyncSimWorld(serverTime: true)
    let adopter = try await world.addDevice("adopter")
    let lost = try await world.addDevice("lost")
    try await world.write(2, on: lost)
    _ = try await lost.engine.upload()
    try await world.write(2, on: lost)
    _ = try await lost.engine.upload()
    try await world.settle()
    let lostID = lost.replica
    let segments = try await SyncAdoptCheck.stored(under: lostID, in: world.log).filter { $0 != VaultPath.manifest(lostID) }
    try #require(segments.count >= 2)
    try await world.remove(lost)
    try await adopter.harness.lifecycle.retire(lostID, successor: adopter.replica)
    world.advance(days: 7)
    for key in segments { adopter.lag.hide(key, listings: hiddenForLong ? 1_000 : 2) }

    for call in 0..<2 {
      #expect(try await adopter.engine.adopt() == .progressed(adopted: [], waiting: [lostID]), "call \(call)")
      #expect(try await SyncAdoptCheck.stored(under: lostID, in: world.log).contains(VaultPath.manifest(lostID)))
      try await world.expectFreshReaderConverges("call \(call)")
      world.advance(days: 1)
    }

    if hiddenForLong {
      world.advance(days: 3)
      #expect(try await adopter.engine.adopt() == .progressed(adopted: [lostID], waiting: []))
      #expect(Set(try await SyncAdoptCheck.stored(under: lostID, in: world.log)) == Set(segments))
      try await world.expectFreshReaderConverges("the manifest given up while the segments are hidden")
      adopter.heal()
    }
    #expect(adopter.lag.omissions > 0)
    #expect(try await adopter.engine.adopt() == .progressed(adopted: [lostID], waiting: []))
    #expect(try await SyncAdoptCheck.stored(under: lostID, in: world.log).isEmpty)
    try await world.settle()
    try await world.verify("the hidden segments adopted")
  }
}
