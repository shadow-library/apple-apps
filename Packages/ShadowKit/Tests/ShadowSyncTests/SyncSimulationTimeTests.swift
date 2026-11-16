import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private let year: TimeInterval = 365 * SyncDays.day

private func segments(in world: SyncSimWorld) async throws -> [ObjectKey] {
  try await world.log.listAll(prefix: VaultPath.replicasPrefix).map(\.key).filter { key in
    guard case .segment = VaultPath.classify(key) else { return false }
    return true
  }
}

private func clocks(of replica: ReplicaID, in world: SyncSimWorld) throws -> [Date] {
  var dates: [Date] = []
  for (key, data) in world.log.putSegments {
    guard case .segment(let owner, _, _, _) = VaultPath.classify(key), owner == replica else { continue }
    let file = try SegmentCodec.open(data, at: key, vault: SyncFixture.vault) { world.observer.key($0) }
    dates += try file.lines.map { try ChangeRecord(json: CanonicalJSON.decode($0)).clock.date }
  }
  return dates
}

/// A stream held at a change stamped ahead of the reader also holds every segment after it.
private func isClockAhead(_ reason: SyncHoldReason) -> Bool {
  reason == .clockAhead || reason == .waitingForPredecessor || SyncSimWorld.isIncompleteBase(reason)
}

/// Monthly compaction, with adoption and its abandonment a month after a retirement.
private let monthly = SyncConfiguration(
  maximumSegmentLines: 3, compactionAge: SyncDays.duration(30), compactionBytes: .max, compactionFiles: 4, compactionInterval: SyncDays.duration(30),
  basePartBytes: 1_500, adoptionDelay: SyncDays.duration(30), adoptionAbandonDelay: SyncDays.duration(30))

/// Recent segments outlive a base, so a reader that cannot list the base still finds every segment's predecessor.
private let recentSegmentsKept = SyncConfiguration(
  maximumSegmentLines: 3, compactionAge: SyncDays.duration(30), compactionBytes: .max, compactionFiles: .max, compactionInterval: .zero, adoptionDelay: SyncDays.duration(2))

@Suite("Sync simulation: late joiners, long absences and wrong clocks")
struct SyncSimulationTimeTests {
  @Test("should bring a new device to every change from bases alone after every replica compacted and a lost one was adopted")
  func shouldJoinFromBasesOnly() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    let mac = try await world.addDevice("mac")
    let lost = try await world.addDevice("lost")
    for round in 0..<3 {
      for device in world.devices {
        try await world.write(3, on: device)
        try await world.contest(round, on: device, purge: round == 2 && device === mac)
      }
      try await world.settle()
    }
    let lostID = lost.replica
    try await world.remove(lost)
    try await phone.harness.lifecycle.retire(lostID, successor: phone.replica)
    world.advance(days: 5)
    try await world.settle()
    for device in world.devices { #expect(try await device.engine.compact(force: true) != .postponed) }
    try await world.settle()
    #expect(try await SyncAdoptCheck.stored(under: lostID, in: world.log).isEmpty)
    #expect(try await segments(in: world).isEmpty, "only bases are left")

    let tablet = try await world.addDevice("tablet")
    let first = try await tablet.engine.download()

    #expect(!first.applied.isEmpty && first.applied.allSatisfy { $0.kind == .base })
    try await world.settle()
    try await world.verify("joined from bases")
  }

  @Test("should return a device a year away, with unsent changes, to every change after monthly compactions, a restore and an adoption, in few downloads")
  func shouldReturnAfterYearAway() async throws {
    let world = try SyncSimWorld(configuration: monthly)
    let phone = try await world.addDevice("phone")
    let mac = try await world.addDevice("mac")
    let lost = try await world.addDevice("lost")
    let away = try await world.addDevice("away")
    for device in world.devices { try await world.write(2, on: device) }
    try await world.settle()
    try await world.write(3, on: away)
    world.offline.insert(away.name)
    var snapshot: URL?

    for fortnight in 0..<26 {
      world.advance(days: 14)
      for device in world.online {
        try await world.write(2, on: device)
        try await world.contest(fortnight % 3, on: device)
      }
      switch fortnight {
      case 3:
        let lostID = lost.replica
        try await world.remove(lost)
        try await phone.harness.lifecycle.retire(lostID, successor: phone.replica)
      case 8:
        snapshot = try world.snapshot(mac)
      case 12:
        try await world.restore(mac, from: try #require(snapshot))
      default:
        break
      }
      try await world.settle()
    }
    try await world.verify("a year on, before the absent device returns")
    #expect(try await SyncAdoptCheck.facts(phone.harness).count >= 2)

    world.offline.remove(away.name)
    try await world.write(1, on: away)
    let replica = away.replica
    var downloads = 0
    let expected = try world.reference(extra: try await away.harness.pendingLines())
    while try await away.harness.digest() != expected, downloads < 20 {
      downloads += 1
      _ = try await away.engine.download()
    }

    #expect(downloads <= 2 * SyncConfiguration().dependencyWaitCalls, "the absent device took \(downloads) downloads")
    #expect(away.replica == replica)
    try await world.settle()
    try await world.verify("the absent device returned")
  }

  @Test(
    "should keep and deliver every change of a device whose clock is a year ahead or behind, re-stamping before upload when the provider reports server time",
    arguments: [(-1.0, false), (-1.0, true), (1.0, true)])
  func shouldConvergeWithWrongWriterClock(_ years: Double, _ serverTime: Bool) async throws {
    let world = try SyncSimWorld(serverTime: serverTime)
    let phone = try await world.addDevice("phone")
    let mac = try await world.addDevice("mac")
    let wrong = try await world.addDevice("wrong", offset: years * year)
    let replica = wrong.replica
    try await world.write(2, on: phone)
    try await world.settle(waits: isClockAhead)
    try await world.write(3, on: wrong)
    try await world.contest(0, on: wrong)
    try await world.contest(0, on: mac)

    try await world.settle(waits: isClockAhead)

    if !serverTime {
      let held = try await wrong.engine.download().held
      #expect(!held.isEmpty && held.values.allSatisfy(isClockAhead), "a reader a year behind holds everything until its clock is fixed")
      world.offline.insert(wrong.name)
      try await world.verify("the others, while the wrong clock holds")
      world.offline.remove(wrong.name)
      wrong.offset.set(0)
      try await world.settle()
    }
    try await world.verify("wrong clock")
    let stamps = try clocks(of: wrong.replica, in: world)
    if serverTime {
      #expect(wrong.replica != replica, "a wrong clock is corrected by a rebuild under a new id")
      guard case .wrong = await wrong.engine.deviceClock else { throw SyncFixtureFailure("the wrong clock was not reported") }
      #expect(stamps.allSatisfy { abs($0.timeIntervalSince(world.clock.now)) < SyncDays.day })
    } else {
      #expect(wrong.replica == replica)
      #expect(stamps.contains { $0 < world.clock.now.addingTimeInterval(-300 * SyncDays.day) })
    }
  }

  @Test("should hold, never reject, the changes of a device a year ahead on a provider with no server time, and deliver them once the readers' clocks pass them")
  func shouldHoldChangesFromYearAheadWithoutServerTime() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    let ahead = try await world.addDevice("ahead", offset: year)
    try await world.write(2, on: phone)
    try await world.write(3, on: ahead)
    try await world.contest(0, on: ahead)

    try await world.settle(waits: isClockAhead)

    let held = try await phone.engine.download().held
    #expect(held.values.contains(.clockAhead) && held.allSatisfy { $0.key.replica == ahead.replica && isClockAhead($0.value) })
    #expect(try await world.missingTitles(try await world.expectedTitles(), on: phone).count == 3)
    await #expect(throws: SyncFixtureFailure.self) { try await world.expectFreshReaderConverges("a year early", calls: 3) }

    world.advance(days: 366)
    try await world.settle()
    try await world.verify("a year later")
  }

  @Test("should apply nothing from a reader whose clock is a year behind until it learns trusted time or its clock is fixed, then converge", arguments: [false, true])
  func shouldReleaseHoldsOfReaderBehind(_ serverTime: Bool) async throws {
    let world = try SyncSimWorld(serverTime: serverTime)
    let phone = try await world.addDevice("phone")
    let behind = try await world.addDevice("behind", offset: -year)
    try await world.write(3, on: phone)
    _ = try await phone.engine.sync()

    let first = try await behind.engine.download()

    #expect(first.applied.isEmpty && first.held.values.contains(.clockAhead))
    _ = try await behind.engine.sync()
    let second = try await behind.engine.download()
    #expect(second.applied.isEmpty == !serverTime)
    if !serverTime { behind.offset.set(0) }
    try await world.write(2, on: behind)
    try await world.settle()
    try await world.verify("the reader's clock is right")
  }

  @Test("should apply an adopter's segments that name the adopted replica, one dependency wait after another, while a reader cannot list the adopter's base")
  func shouldWaitPerSegmentWithoutAdoptersBase() async throws {
    let target = SyncSimTarget()
    let world = try SyncSimWorld(configuration: recentSegmentsKept)
    let adopter = try await world.addDevice("adopter")
    target.set(adopter.replica)
    let lost = try await world.addDevice("lost")
    let reader = try await world.addDevice("reader", faults: SyncSimFaults(lag: 1, lagListings: 1_000...1_000, lagged: target.isBasePart))
    try await world.write(3, on: lost)
    try await world.write(3, on: adopter)
    for device in [lost, adopter] { _ = try await device.engine.upload() }
    _ = try await reader.engine.download()
    try await world.write(3, on: lost)
    _ = try await lost.engine.upload()
    _ = try await adopter.engine.sync()
    let lostID = lost.replica
    try await world.remove(lost)
    try await adopter.harness.lifecycle.retire(lostID, successor: adopter.replica)
    world.advance(days: 5)
    #expect(try await adopter.engine.adopt() == .progressed(adopted: [lostID], waiting: []))
    let segments = 5
    for _ in 0..<segments {
      try await world.write(1, on: adopter)
      _ = try await adopter.engine.upload()
    }
    let written = try await SyncStoredFiles.read(adopter.replica, in: world.log).segments

    var downloads = 0
    while try await reader.harness.appliedFiles()[adopter.replica]?.segments.isSuperset(of: written) != true, downloads < 40 {
      downloads += 1
      _ = try await reader.engine.download()
    }

    let waits = SyncConfiguration().dependencyWaitCalls
    #expect(downloads <= (segments + 1) * waits + 1, "the reader took \(downloads) downloads for \(written.count) segments")
    try await world.settle()
    try await world.verify("the base listed again")
  }
}
