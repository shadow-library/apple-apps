import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func stored(under replica: ReplicaID, in world: SyncSimWorld) async throws -> [ObjectKey] {
  try await SyncAdoptCheck.stored(under: replica, in: world.log)
}

/// Lets the adoption delay pass, settles, and checks that nothing is left under `retired`.
private func expectAdopted(_ retired: [ReplicaID], in world: SyncSimWorld, _ label: String) async throws {
  world.advance(days: 5)
  try await world.settle()
  try await world.verify(label)
  for replica in retired {
    let left = try await stored(under: replica, in: world)
    #expect(left.isEmpty, "\(label): files left under \(replica): \(left)")
  }
}

@Suite("Sync simulation: replica lifecycle on the local-folder provider")
struct SyncSimulationLifecycleTests {
  @Test("should re-mint a database restored from an old copy, give back every change it had uploaded since, and lose nothing when restored again from the same copy")
  func shouldRecoverRestoredDatabase() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    let mac = try await world.addDevice("mac")
    try await world.write(4, on: phone)
    try await world.write(3, on: mac)
    try await world.settle()
    let copy = try world.snapshot(phone)
    let original = phone.replica

    try await world.write(5, on: phone)
    try await world.contest(0, on: phone)
    _ = try await phone.engine.sync()
    #expect(try await phone.engine.compact(force: true) != .postponed)
    _ = try await mac.engine.sync()
    try await world.write(2, on: phone)
    try await world.restore(phone, from: copy)
    try await world.expectFreshReaderConverges("restored, before it syncs")

    try await world.write(2, on: phone)
    try await world.contest(0, on: mac)
    _ = try await phone.engine.sync()

    #expect(phone.replica != original)
    let directory = try await phone.harness.lifecycle.directory()
    #expect(directory.entry(for: original)?.state == .retired && directory.entry(for: original)?.successor == phone.replica)
    try await world.settle()
    try await world.verify("after the first restore")

    let second = phone.replica
    let bootstrap = try await world.restore(phone, from: copy)
    #expect(bootstrap == .reminted(from: original, reason: .markerNamesOther(second)))
    #expect(![original, second].contains(phone.replica))
    try await world.write(1, on: phone)
    try await world.settle()
    try await world.verify("after the second restore, the id the marker named still active")
    try await phone.harness.lifecycle.retire(second, successor: phone.replica)
    try await world.settle()
    try await world.verify("after the second restore")
    try await expectAdopted([original, second], in: world, "after adoption")
  }

  @Test("should split a live clone from its original while both keep writing, upload the unsent changes both held, and adopt the shared id")
  func shouldSplitLiveClone() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    let mac = try await world.addDevice("mac")
    try await world.write(3, on: phone)
    try await world.settle()
    try await world.write(3, on: phone)
    let shared = phone.replica

    let tablet = try await world.clone(phone, as: "tablet")

    #expect(tablet.replica != shared)
    for round in 0..<4 {
      try await world.write(2, on: phone)
      try await world.write(2, on: tablet)
      try await world.contest(round % 2, on: phone)
      try await world.contest(round % 2, on: tablet)
      for device in [tablet, phone, mac] { _ = try await device.engine.sync() }
      try await world.expectFreshReaderConverges("clone round \(round)")
    }
    try await world.settle()
    #expect(phone.replica != shared, "the original re-mints once it reads that its id was retired")
    try await world.verify("after the clone")
    try await expectAdopted([shared], in: world, "after adoption")
  }

  @Test("should bring a reinstalled app back to every change it had uploaded, and adopt its old replica once the user retires it")
  func shouldRecoverAfterReinstall() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    let mac = try await world.addDevice("mac")
    try await world.write(4, on: phone)
    try await world.write(2, on: mac)
    try await world.settle()
    try await world.write(3, on: phone)
    _ = try await phone.engine.upload()
    try await world.write(2, on: phone)

    let old = try await world.reinstall(phone)

    #expect(phone.replica != old)
    try await world.settle()
    try await world.verify("reinstalled, the old replica still active")
    #expect(try await phone.harness.lifecycle.directory().entry(for: old)?.state == .active)
    try await phone.harness.lifecycle.retire(old, successor: phone.replica)
    try await world.write(1, on: phone)
    try await world.settle()
    try await world.verify("retired")
    try await expectAdopted([old], in: world, "after adoption")
  }

  @Test("should carry a lost device's changes through its adopter and the adopter's adopter, and take back a retired owner that returns with unsent changes")
  func shouldAdoptThroughChainAndOwnerReturn() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    let mac = try await world.addDevice("mac")
    let lost = try await world.addDevice("lost")
    let away = try await world.addDevice("away")
    for device in world.devices { try await world.write(3, on: device) }
    try await world.settle()

    try await world.write(2, on: lost)
    let lostID = lost.replica
    try await world.remove(lost)
    try await mac.harness.lifecycle.retire(lostID, successor: mac.replica)
    try await expectAdopted([lostID], in: world, "the lost device adopted")

    let macID = mac.replica
    try await world.write(2, on: mac)
    _ = try await mac.engine.sync()
    try await world.remove(mac)
    try await phone.harness.lifecycle.retire(macID, successor: phone.replica)
    try await expectAdopted([macID, lostID], in: world, "the adopter adopted")

    let awayID = away.replica
    world.offline.insert(away.name)
    try await world.write(3, on: away)
    try await phone.harness.lifecycle.retire(awayID, successor: phone.replica)
    try await expectAdopted([awayID], in: world, "the absent device adopted")

    world.offline.remove(away.name)
    try await world.write(1, on: away)
    _ = try await away.engine.sync()
    #expect(away.replica != awayID)
    try await world.settle()
    try await world.verify("the owner returned")
    try await expectAdopted([awayID], in: world, "the owner's late files adopted")
  }

  @Test("should lose nothing, and should finish the adoption, when the original keeps writing under a shared id its clone already adopted")
  func shouldAdoptTailWrittenAfterCloneAdopted() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    try await world.write(3, on: phone)
    _ = try await phone.engine.upload()
    let shared = phone.replica
    let tablet = try await world.clone(phone, as: "tablet")
    world.offline.insert(phone.name)
    try await expectAdopted([shared], in: world, "the clone adopted the shared id")
    try await world.write(2, on: tablet)
    try await world.write(2, on: phone)
    #expect(try await phone.engine.upload() != .nothingToUpload)
    #expect(phone.replica == shared)

    world.offline.remove(phone.name)
    try await world.settle()
    world.advance(days: 5)
    try await world.settle()

    #expect(phone.replica != shared)
    try await world.verify("the original's late segments")
    await withKnownIssue("the chain now ends at the original, whose head starts at 0 because only the clone's base holds what the clone's fact covers") {
      let left = try await stored(under: shared, in: world)
      #expect(left.isEmpty, "files left under the shared id: \(left)")
    }
  }

  @Test("should adopt in a later pass a segment a retired owner put after its adoption, once the owner is gone")
  func shouldAdoptSegmentPutAfterAdoption() async throws {
    let world = try SyncSimWorld()
    let phone = try await world.addDevice("phone")
    let away = try await world.addDevice("away")
    for device in world.devices { try await world.write(3, on: device) }
    try await world.settle()
    let awayID = away.replica
    world.offline.insert(away.name)
    try await phone.harness.lifecycle.retire(awayID, successor: phone.replica)
    try await expectAdopted([awayID], in: world, "the absent device adopted")

    try await world.write(2, on: away)
    #expect(try await away.engine.upload() != .nothingToUpload)
    #expect(try await !stored(under: awayID, in: world).isEmpty)
    try await world.remove(away)

    try await expectAdopted([awayID], in: world, "the late segment adopted")
  }

  @Test("should adopt a late segment of a replica whose adopter was itself retired and adopted, holding the first fact's head through the adopter's base")
  func shouldAdoptLateSegmentThroughAdoptersAdopter() async throws {
    let world = try SyncSimWorld()
    let first = try await world.addDevice("first")
    let second = try await world.addDevice("second")
    let away = try await world.addDevice("away")
    for device in world.devices { try await world.write(3, on: device) }
    try await world.settle()
    let awayID = away.replica
    world.offline.insert(away.name)
    try await first.harness.lifecycle.retire(awayID, successor: first.replica)
    try await expectAdopted([awayID], in: world, "the absent device adopted")

    let firstID = first.replica
    try await world.write(2, on: first)
    _ = try await first.engine.sync()
    try await world.remove(first)
    try await second.harness.lifecycle.retire(firstID, successor: second.replica)
    try await expectAdopted([firstID], in: world, "the adopter adopted")

    try await world.write(2, on: away)
    #expect(try await away.engine.upload() != .nothingToUpload)
    try await world.remove(away)

    try await expectAdopted([awayID, firstID], in: world, "the late segment adopted through the adopter's base")
  }
}
