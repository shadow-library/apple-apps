import Foundation
import ShadowCore
import ShadowKeychain
import ShadowTestSupport
import Testing

@testable import ShadowStore
@testable import ShadowSync

private let vault = ReplicaFixture.vault
private let noteRef = EntityRef(kind: ReplicaFixture.note, key: ReplicaFixture.key("n1"))

extension VaultStore {
  fileprivate func merge(_ records: [ChangeRecord]) async throws {
    try await write { transaction in
      for record in records { try transaction.apply(record) }
    }
  }

  fileprivate func writeNote(_ title: String) async throws {
    try await write { transaction in _ = try transaction.set(noteRef, ["title": .string(title)]) }
  }

  fileprivate func recordSegment(_ point: StreamPoint, first: Int64) async throws {
    let replica = replica
    try await write { transaction in try ReplicaHistory.recordSegment(point, first: first, replica: replica, at: 1, in: transaction.database) }
  }
}

private func garble(_ keychain: InMemoryKeychain, _ device: String) throws {
  try keychain.device(device).store(service: "marker", scope: .device).setData(Data("garbage".utf8), forKey: DeviceMarker.itemName(vault: vault))
}

@Suite("ReplicaLifecycle")
struct ReplicaLifecycleTests {
  @Test("should claim the marker on a fresh install and declare the replica active")
  func shouldClaimFreshInstall() async throws {
    let marker = ReplicaFixture.marker(InMemoryKeychain(), "phone")
    let store = try ReplicaFixture.open()
    let opened = store.replica
    let minter = ReplicaMinter()
    let lifecycle = ReplicaFixture.lifecycle(store, marker: marker, minter: minter)
    #expect(try await lifecycle.bootstrap() == .claimed(previous: nil))
    let replica = store.replica
    #expect(minter.all == [replica] && replica != opened)
    #expect(marker.status(vault: vault, replica: replica) == .matches)
    #expect(try await lifecycle.directory().replicas.map(\.replica) == [replica])
    let entry = try #require(try await lifecycle.directory().entry(for: replica))
    #expect(entry.state == .active && entry.name == "Phone" && entry.platform == "iOS" && entry.created == ReplicaFixture.startMillis && entry.successor == nil)
    #expect(try await lifecycle.selfCheck(listing: [VaultPath.manifest(replica)]) == .pass)
  }

  @Test("should report an already running replica on the next launch and refresh only what changed")
  func shouldRunAgain() async throws {
    let marker = ReplicaFixture.marker(InMemoryKeychain(), "phone")
    let store = try ReplicaFixture.open()
    _ = try await ReplicaFixture.lifecycle(store, marker: marker).bootstrap()
    let count = try await ReplicaFixture.records(store).count
    #expect(try await ReplicaFixture.lifecycle(store, marker: marker).bootstrap() == .alreadyRunning)
    #expect(try await ReplicaFixture.records(store).count == count)
    var renamed = ReplicaFixture.phone
    renamed.name = "Work Phone"
    let lifecycle = ReplicaFixture.lifecycle(store, marker: marker, device: renamed)
    #expect(try await lifecycle.bootstrap() == .alreadyRunning)
    let records = try await ReplicaFixture.records(store)
    #expect(records.count == count + 1 && records.last?.fields.keys.sorted() == ["name"])
    #expect(try await lifecycle.directory().entry(for: store.replica)?.name == "Work Phone")
  }

  @Test("should mint a new id after a reinstall and name the replica the surviving marker held")
  func shouldReportPreviousAfterReinstall() async throws {
    let marker = ReplicaFixture.marker(InMemoryKeychain(), "phone")
    let old = try ReplicaFixture.open()
    _ = try await ReplicaFixture.lifecycle(old, marker: marker).bootstrap()
    let reinstalled = try ReplicaFixture.open()
    let opened = reinstalled.replica
    #expect(try await ReplicaFixture.lifecycle(reinstalled, marker: marker).bootstrap() == .claimed(previous: old.replica))
    #expect(reinstalled.replica != opened && reinstalled.replica != old.replica)
    #expect(marker.status(vault: vault, replica: reinstalled.replica) == .matches)
  }

  @Test("should keep local writes made before the first claim and re-log them under the claimed id")
  func shouldKeepWritesBeforeClaim() async throws {
    let store = try ReplicaFixture.open()
    try await store.writeNote("offline")
    let pending = try await store.pendingChanges(limit: Int.max)
    let vaultBefore = try await store.loadState(.vault)
    let lifecycle = ReplicaFixture.lifecycle(store, marker: ReplicaFixture.marker(InMemoryKeychain(), "phone"))
    #expect(try await lifecycle.bootstrap() == .claimed(previous: nil))
    let after = try await store.pendingChanges(limit: Int.max)
    #expect(after.prefix(pending.count).map(\.line) == pending.map(\.line))
    let added = try await ReplicaFixture.records(store).dropFirst(pending.count)
    #expect(added.allSatisfy { $0.ref == SyncKernelSchema.replicaRef(store.replica) })
    var expected = vaultBefore
    for record in added { expected.apply(record, registry: ReplicaFixture.registry) }
    #expect(try await store.loadState(.vault) == expected)
  }

  @Test("should give a fresh database copied to two devices two distinct ids")
  func shouldSplitFreshCopies() async throws {
    let keychain = InMemoryKeychain()
    let directory = ReplicaTemporaryDirectory()
    let opened = try ReplicaFixture.open(.file(directory.database("phone"))).replica
    try ReplicaFixture.copyDatabase(from: directory.database("phone"), to: directory.database("mac"))
    let phone = try ReplicaFixture.open(.file(directory.database("phone")))
    let mac = try ReplicaFixture.open(.file(directory.database("mac")))
    #expect(try await ReplicaFixture.lifecycle(phone, marker: ReplicaFixture.marker(keychain, "phone")).bootstrap() == .claimed(previous: nil))
    #expect(try await ReplicaFixture.lifecycle(mac, marker: ReplicaFixture.marker(keychain, "mac"), device: ReplicaFixture.mac).bootstrap() == .claimed(previous: nil))
    #expect(Set([opened, phone.replica, mac.replica]).count == 3)
  }

  @Test("should report corrupt state instead of retiring anything when the store was re-minted behind the lifecycle's back")
  func shouldDetectForeignRemint() async throws {
    let marker = ReplicaFixture.marker(InMemoryKeychain(), "phone")
    let store = try ReplicaFixture.open()
    let lifecycle = ReplicaFixture.lifecycle(store, marker: marker)
    _ = try await lifecycle.bootstrap()
    let claimed = store.replica
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .keepState)
    let count = try await ReplicaFixture.records(store).count
    let boot = await #expect(throws: ReplicaLifecycleError.self) { try await lifecycle.bootstrap() }
    let check = await #expect(throws: ReplicaLifecycleError.self) { try await lifecycle.selfCheck(listing: []) }
    let remint = await #expect(throws: ReplicaLifecycleError.self) { try await lifecycle.remint(reason: .retired) }
    #expect([boot, check, remint].allSatisfy { $0?.code == "replica-lifecycle.corrupt-state" })
    #expect(try await ReplicaFixture.records(store).count == count)
    #expect(try await !lifecycle.directory().isRetired(claimed))
    #expect(marker.status(vault: vault, replica: claimed) == .matches)
  }

  @Test("should re-mint a database copied onto a second device and leave the original running")
  func shouldRemintCopy() async throws {
    let keychain = InMemoryKeychain()
    let directory = ReplicaTemporaryDirectory()
    let original = try ReplicaFixture.open(.file(directory.database("phone")))
    let phone = ReplicaFixture.marker(keychain, "phone")
    _ = try await ReplicaFixture.lifecycle(original, marker: phone).bootstrap()
    try await original.writeNote("before copy")
    let replica = original.replica
    try ReplicaFixture.copyDatabase(from: directory.database("phone"), to: directory.database("mac"))

    let copy = try ReplicaFixture.open(.file(directory.database("mac")))
    let mac = ReplicaFixture.marker(keychain, "mac")
    let copyLifecycle = ReplicaFixture.lifecycle(copy, marker: mac, device: ReplicaFixture.mac)
    #expect(try await copyLifecycle.bootstrap() == .reminted(from: replica, reason: .markerMissing))
    #expect(copy.replica != replica)
    #expect(mac.status(vault: vault, replica: copy.replica) == .matches)
    let seen = try await copyLifecycle.directory()
    #expect(seen.entry(for: replica)?.state == .retired && seen.entry(for: replica)?.successor == copy.replica)
    #expect(seen.entry(for: copy.replica)?.state == .active && seen.entry(for: copy.replica)?.name == "Mac")
    #expect(try await ReplicaFixture.records(copy).contains { $0.entity == ReplicaFixture.note })
    #expect(try await copyLifecycle.bootstrap() == .alreadyRunning)

    #expect(try await ReplicaFixture.lifecycle(original, marker: phone).bootstrap() == .alreadyRunning)
    #expect(original.replica == replica)
  }

  @Test("should run an older copy restored on the same device until the self-check sees a segment it does not remember")
  func shouldCatchRestoreOnSameDevice() async throws {
    let directory = ReplicaTemporaryDirectory()
    let marker = ReplicaFixture.marker(InMemoryKeychain(), "phone")
    let live = try ReplicaFixture.open(.file(directory.database("live")))
    _ = try await ReplicaFixture.lifecycle(live, marker: marker).bootstrap()
    let replica = live.replica
    try await live.recordSegment(ReplicaFixture.point(5, 1), first: 1)
    try ReplicaFixture.copyDatabase(from: directory.database("live"), to: directory.database("backup"))
    try await live.recordSegment(ReplicaFixture.point(9, 2), first: 6)

    let restored = try ReplicaFixture.open(.file(directory.database("backup")))
    let lifecycle = ReplicaFixture.lifecycle(restored, marker: marker)
    #expect(try await lifecycle.bootstrap() == .alreadyRunning)
    let listing = [
      VaultPath.manifest(replica),
      VaultPath.segment(replica, first: 1, last: 5, tag: ReplicaFixture.tag(1)),
      VaultPath.segment(replica, first: 6, last: 9, tag: ReplicaFixture.tag(2)),
    ]
    #expect(try await lifecycle.selfCheck(listing: Array(listing.prefix(2))) == .pass)
    #expect(try await lifecycle.selfCheck(listing: listing) == .remint(.unknownSegment(ReplicaFixture.point(9, 2))))
  }

  @Test("should give the re-mint verdict once another device retired this replica")
  func shouldSeeRetirementByOthers() async throws {
    let keychain = InMemoryKeychain()
    let phoneStore = try ReplicaFixture.open()
    let phone = ReplicaFixture.lifecycle(phoneStore, marker: ReplicaFixture.marker(keychain, "phone"))
    _ = try await phone.bootstrap()
    let macStore = try ReplicaFixture.open()
    let mac = ReplicaFixture.lifecycle(macStore, marker: ReplicaFixture.marker(keychain, "mac"), device: ReplicaFixture.mac)
    _ = try await mac.bootstrap()
    try await mac.retire(phoneStore.replica)
    try await phoneStore.merge(ReplicaFixture.replicaRecords(try await ReplicaFixture.records(macStore), for: phoneStore.replica))
    #expect(try await phone.directory().isRetired(phoneStore.replica))
    #expect(try await phone.selfCheck(listing: []) == .remint(.retired))
  }

  @Test("should keep pending changes and the vault state, change the id, and start a new history while keeping the old one")
  func shouldRemintKeepingState() async throws {
    let marker = ReplicaFixture.marker(InMemoryKeychain(), "phone")
    let store = try ReplicaFixture.open()
    let minter = ReplicaMinter()
    let lifecycle = ReplicaFixture.lifecycle(store, marker: marker, minter: minter)
    _ = try await lifecycle.bootstrap()
    let old = store.replica
    try await store.writeNote("one")
    try await store.writeNote("two")
    try await store.recordSegment(ReplicaFixture.point(5, 1), first: 1)
    let vaultBefore = try await store.loadState(.vault)
    let pendingBefore = try await store.pendingChanges(limit: Int.max)

    let reason = RemintReason.unknownSegment(ReplicaFixture.point(9, 9))
    let new = try await lifecycle.remint(reason: reason)
    #expect(minter.all == [old, new] && store.replica == new)
    #expect(marker.status(vault: vault, replica: new) == .matches)
    let pendingAfter = try await store.pendingChanges(limit: Int.max)
    #expect(pendingAfter.prefix(pendingBefore.count).map(\.line) == pendingBefore.map(\.line))
    let added = try await ReplicaFixture.records(store).dropFirst(pendingBefore.count)
    #expect(Set(added.map(\.ref)) == [SyncKernelSchema.replicaRef(old), SyncKernelSchema.replicaRef(new)])
    var expected = vaultBefore
    for record in added { expected.apply(record, registry: ReplicaFixture.registry) }
    #expect(try await store.loadState(.vault) == expected)

    let (oldHistory, newHistory) = try await store.read { transaction in
      (try ReplicaHistory.uploads(of: old, in: transaction.database), try ReplicaHistory.uploads(of: new, in: transaction.database))
    }
    #expect(oldHistory.segments == [ReplicaFixture.point(5, 1)] && newHistory == ReplicaUploadHistory())
    let seen = try await lifecycle.directory()
    #expect(seen.entry(for: old)?.state == .retired && seen.entry(for: old)?.successor == new && seen.entry(for: new)?.state == .active)
    #expect(try await lifecycle.bootstrap() == .alreadyRunning)
    #expect(try await lifecycle.selfCheck(listing: []) == .pass)
  }

  @Test("should re-stamp pending changes under the new id when rebuilding")
  func shouldRemintRebuilding() async throws {
    let store = try ReplicaFixture.open()
    let lifecycle = ReplicaFixture.lifecycle(store, marker: ReplicaFixture.marker(InMemoryKeychain(), "phone"))
    _ = try await lifecycle.bootstrap()
    try await store.writeNote("one")
    let new = try await lifecycle.remint(reason: .retired, mode: .rebuild)
    #expect(try await ReplicaFixture.records(store).allSatisfy { $0.clock.replica == new })
  }

  @Test("should change nothing while the marker is unreadable")
  func shouldWaitForUnreadableMarker() async throws {
    let keychain = InMemoryKeychain()
    let marker = ReplicaFixture.marker(keychain, "phone")
    let fresh = try ReplicaFixture.open()
    try garble(keychain, "phone")
    let freshLifecycle = ReplicaFixture.lifecycle(fresh, marker: marker)
    let error = await #expect(throws: ReplicaLifecycleError.self) { try await freshLifecycle.bootstrap() }
    #expect(error?.code == "replica-lifecycle.marker-unavailable")
    #expect(try await ReplicaFixture.records(fresh).isEmpty)
    try marker.clear(vault: vault)
    #expect(try await freshLifecycle.bootstrap() == .claimed(previous: nil))

    let replica = fresh.replica
    let count = try await ReplicaFixture.records(fresh).count
    try garble(keychain, "phone")
    let minter = ReplicaMinter()
    let lifecycle = ReplicaFixture.lifecycle(fresh, marker: marker, minter: minter)
    await #expect(throws: ReplicaLifecycleError.self) { try await lifecycle.bootstrap() }
    await #expect(throws: ReplicaLifecycleError.self) { _ = try await lifecycle.remint(reason: .retired) }
    #expect(try await lifecycle.selfCheck(listing: []) == .postpone)
    #expect(fresh.replica == replica && minter.all.isEmpty)
    #expect(try await ReplicaFixture.records(fresh).count == count)
  }

  @Test("should refuse to retire the replica this device writes as")
  func shouldRefuseRetiringCurrent() async throws {
    let store = try ReplicaFixture.open()
    let lifecycle = ReplicaFixture.lifecycle(store, marker: ReplicaFixture.marker(InMemoryKeychain(), "phone"))
    _ = try await lifecycle.bootstrap()
    let error = await #expect(throws: ReplicaLifecycleError.self) { try await lifecycle.retire(store.replica) }
    #expect(error?.code == "replica-lifecycle.retiring-current-replica")
    #expect(try await !lifecycle.directory().isRetired(store.replica))
    let other = ReplicaFixture.replica("01936f3e-2222-7222-8222-222222222222")
    try await lifecycle.retire(other, successor: store.replica)
    #expect(try await lifecycle.directory().entry(for: other)?.successor == store.replica)
    #expect(try await lifecycle.directory().isRetired(other))
  }

  @Test("should refuse the self-check and re-mint before bootstrap")
  func shouldRequireBootstrap() async throws {
    let lifecycle = ReplicaFixture.lifecycle(try ReplicaFixture.open(), marker: ReplicaFixture.marker(InMemoryKeychain(), "phone"))
    let check = await #expect(throws: ReplicaLifecycleError.self) { _ = try await lifecycle.selfCheck(listing: []) }
    let remint = await #expect(throws: ReplicaLifecycleError.self) { _ = try await lifecycle.remint(reason: .retired) }
    #expect(check?.code == "replica-lifecycle.bootstrap-required" && remint?.code == "replica-lifecycle.bootstrap-required")
  }

  @Test("should build the manifest from the device, the registry, the history and the applied points")
  func shouldBuildManifest() async throws {
    let store = try ReplicaFixture.open()
    let lifecycle = ReplicaFixture.lifecycle(store, marker: ReplicaFixture.marker(InMemoryKeychain(), "phone"))
    _ = try await lifecycle.bootstrap()
    let replica = store.replica
    try await store.write { transaction in
      let db = transaction.database
      try ReplicaHistory.recordSegment(ReplicaFixture.point(5, 1), first: 1, replica: replica, at: 1, in: db)
      try ReplicaHistory.recordSegment(ReplicaFixture.point(9, 2), first: 6, replica: replica, at: 2, in: db)
      try ReplicaHistory.recordBase(ReplicaFixture.point(5, 3), parts: 2, replica: replica, at: 3, in: db)
      try ReplicaHistory.recordBase(ReplicaFixture.point(9, 4), parts: 1, replica: replica, at: 4, in: db)
      try ReplicaHistory.markDeleted(ReplicaFixture.point(5, 3), isBase: true, replica: replica, at: 5, in: db)
    }
    let other = ReplicaFixture.replica("01936f3e-2222-7222-8222-222222222222")
    let manifest = try await lifecycle.manifest(applied: [other: ReplicaFixture.point(3, 7), replica: ReplicaFixture.point(9, 2)])
    let base = try #require(BaseReference(upTo: 9, tag: ReplicaFixture.tag(4), parts: 1))
    let expected = ReplicaManifest(
      replica: replica, deviceName: "Phone", platform: "iOS", appVersion: "1.0", schema: 3, head: ReplicaFixture.point(9, 2), base: base,
      applied: [other: ReplicaFixture.point(3, 7)], updatedMillis: ReplicaFixture.startMillis)
    #expect(manifest == expected)
    _ = try ReplicaManifestCodec.seal(manifest, vault: vault, with: try CodecFixtures.key())
  }
}
