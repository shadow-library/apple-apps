import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncCloudKit

@Suite("CloudKitStorageProvider failures", TestTimeLimit.quick)
struct CloudKitFailureTests {
  @Test("should create the zone on the first put when it has never existed, and list nothing before")
  func createsZoneOnFirstPut() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    #expect(try await CloudKitFixture.keys(provider).isEmpty)
    await #expect(throws: StorageError.notFound(try CloudKitFixture.key("vault.json"))) { try await provider.get(try CloudKitFixture.key("vault.json")) }
    try await provider.delete([try CloudKitFixture.key("vault.json")])
    #expect(fake.zoneExists == false)
    let receipt = try await provider.put(try CloudKitFixture.key("vault.json"), data: Data([1]), condition: .ifAbsent)
    #expect(receipt.serverTime != nil)
    #expect(fake.zoneExists)
    #expect(fake.callCount(.ensureZone) == 1)
    #expect(try await provider.condition() == nil)
  }

  @Test("should not take a zone it just created and still cannot write to for a lost one")
  func toleratesSlowZoneCreation() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    fake.inject(.zoneMissing(.missing), on: .save, times: 2)
    let key = try CloudKitFixture.key("vault.json")
    await #expect(throws: StorageError.unavailable("The vault's iCloud zone was created but cannot be written yet.")) {
      try await provider.put(key, data: Data([1]), condition: .ifAbsent)
    }
    #expect(try await provider.condition() == nil)
    _ = try await provider.put(key, data: Data([1]), condition: .ifAbsent)
    #expect(fake.callCount(.ensureZone) == 1)
  }

  @Test("should not take a zone created by a put while a catch-up was out for a lost one")
  func toleratesCatchUpRacingTheFirstPut() async throws {
    let fake = FakeCloudKitZone()
    let gated = GatedZone(fake)
    let store = InMemoryCloudKitStateStore()
    let provider = CloudKitStorageProvider(client: gated, stateStore: store, tuning: CloudKitTuning())
    await gated.arm()
    let listing = Task { try await CloudKitFixture.keys(provider) }
    await gated.waitUntilHeld()
    let key = try CloudKitFixture.key("vault.json")
    _ = try await provider.put(key, data: Data([1]), condition: .ifAbsent)
    await gated.release()
    #expect(try await listing.value.allSatisfy { $0 == "vault.json" })
    #expect(try await provider.condition() == nil)
    #expect(await store.state?.zoneStatus == .present)
    #expect(try await CloudKitFixture.keys(provider) == ["vault.json"])
  }

  @Test("should let two first puts both create the zone")
  func toleratesConcurrentFirstPuts() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let keys = try (0..<6).map { try CloudKitFixture.key("first/\($0)") }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for key in keys { group.addTask { _ = try await provider.put(key, data: Data([1]), condition: .ifAbsent) } }
      try await group.waitForAll()
    }
    #expect(try await provider.condition() == nil)
    #expect(try await CloudKitFixture.keys(provider) == keys.map(\.rawValue))
  }

  @Test("should bind the index to the account and refuse every call when another account signed in while the app was away")
  func bindsToAccount() async throws {
    let fake = FakeCloudKitZone()
    let store = InMemoryCloudKitStateStore()
    let first = CloudKitFixture.provider(fake, store: store)
    _ = try await first.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    #expect(await store.state?.userRecordName == "user-1")
    fake.signIn("user-2", notify: false)
    let second = CloudKitFixture.provider(fake, store: store)
    let conditions = second.conditionChanges()
    let change = CloudKitAccountChange.switched(previous: "user-1", current: "user-2")
    await #expect(throws: CloudKitStorageCondition.accountChanged(change).error) {
      try await second.put(try CloudKitFixture.key("b"), data: Data([1]), condition: .overwrite)
    }
    #expect(await CloudKitFixture.first(conditions) == .accountChanged(change))
    #expect(fake.zoneExists == false)
    #expect(fake.callCount(.save) == 2)
    #expect(await store.state?.accountChange == change)
  }

  @Test("should check the account again after a sign-in event, as when the engine lost its state")
  func rechecksAccountOnSignIn() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let conditions = provider.conditionChanges()
    _ = try await provider.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    fake.signIn("user-2", notify: false)
    fake.send(.accountChanged(.signedIn(current: "user-2")))
    #expect(await CloudKitFixture.first(conditions) == .accountChanged(.switched(previous: "user-1", current: "user-2")))
    await #expect(throws: CloudKitStorageCondition.accountChanged(.switched(previous: "user-1", current: "user-2")).error) {
      try await provider.listAll(prefix: "")
    }
  }

  @Test("should answer a put-if-absent over an existing record with alreadyExists and leave the record")
  func refusesExistingRecords() async throws {
    let fake = FakeCloudKitZone()
    let mine = CloudKitFixture.provider(fake)
    let theirs = CloudKitFixture.provider(fake)
    let key = try CloudKitFixture.key("vault.json")
    _ = try await theirs.put(key, data: Data([1]), condition: .ifAbsent)
    await #expect(throws: StorageError.alreadyExists(key)) { try await mine.put(key, data: Data([2]), condition: .ifAbsent) }
    #expect(try await mine.get(key) == Data([1]))
  }

  @Test("should report a full quota and keep the index unchanged")
  func reportsQuota() async throws {
    let fake = FakeCloudKitZone()
    fake.configureLimits { $0.quotaBytes = 10 }
    let provider = CloudKitFixture.provider(fake)
    _ = try await provider.put(try CloudKitFixture.key("a"), data: Data(count: 8), condition: .overwrite)
    await #expect(throws: StorageError.quotaExceeded) { try await provider.put(try CloudKitFixture.key("b"), data: Data(count: 3), condition: .overwrite) }
    #expect(try await CloudKitFixture.keys(provider) == ["a"])
    _ = try await provider.put(try CloudKitFixture.key("a"), data: Data(count: 10), condition: .overwrite)
  }

  @Test("should pass on a rate limit with its retry-after from any call")
  func passesRateLimits() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let key = try CloudKitFixture.key("a")
    _ = try await provider.put(key, data: Data([1]), condition: .overwrite)
    let limited = StorageError.rateLimited(retryAfter: .seconds(30))
    for operation in [FakeCloudKitZone.Operation.save, .fetch, .fetchChanges, .delete] { fake.inject(.storage(limited), on: operation) }
    await #expect(throws: limited) { try await provider.put(key, data: Data([2]), condition: .overwrite) }
    await #expect(throws: limited) { try await provider.get(key) }
    await #expect(throws: limited) { try await provider.listAll(prefix: "") }
    await #expect(throws: limited) { try await provider.delete([key]) }
    #expect(try await provider.get(key) == Data([1]))
  }

  @Test("should record every deletion that succeeded and throw the most telling failure of a partial batch")
  func handlesPartialDeletes() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let keys = try ["a", "b", "c", "d"].map(CloudKitFixture.key)
    for key in keys { _ = try await provider.put(key, data: Data([1]), condition: .overwrite) }
    fake.failRecord(CloudKitRecordLayout.recordName(of: keys[1]), with: .storage(.unavailable("busy")))
    fake.failRecord(CloudKitRecordLayout.recordName(of: keys[2]), with: .storage(.rateLimited(retryAfter: .seconds(5))))
    await #expect(throws: StorageError.rateLimited(retryAfter: .seconds(5))) { try await provider.delete(keys) }
    #expect(try await CloudKitFixture.keys(provider) == ["b", "c"])
    fake.failRecord(CloudKitRecordLayout.recordName(of: keys[1]), with: nil)
    fake.failRecord(CloudKitRecordLayout.recordName(of: keys[2]), with: nil)
    try await provider.delete(keys)
    #expect(try await CloudKitFixture.keys(provider).isEmpty)
  }

  @Test("should halve a batch CloudKit finds too large until every part fits")
  func splitsBatches() async throws {
    let fake = FakeCloudKitZone()
    fake.configureLimits { $0.maxRecordsPerRequest = 3 }
    var tuning = CloudKitTuning()
    tuning.batchSize = 10
    let provider = CloudKitFixture.provider(fake, tuning: tuning)
    let keys = try (0..<10).map { try CloudKitFixture.key("k\($0)") }
    for key in keys { _ = try await provider.put(key, data: Data([1]), condition: .overwrite) }
    try await provider.delete(keys + keys)
    #expect(try await CloudKitFixture.keys(provider).isEmpty)
    #expect(fake.batchSizes(.delete) == [10, 5, 2, 3, 5, 2, 3])
  }

  @Test("should surface a deleted zone as an event and a lasting condition, and refuse to create it again until asked")
  func surfacesZoneDeletion() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let conditions = provider.conditionChanges()
    let key = try CloudKitFixture.key("a")
    _ = try await provider.put(key, data: Data([1]), condition: .overwrite)
    fake.deleteZone(.purged)
    #expect(await CloudKitFixture.first(conditions) == .zoneLost(.purged))
    #expect(try await provider.condition() == .zoneLost(.purged))
    let refused = StorageError.unavailable(CloudKitZoneLoss.purged.explanation)
    await #expect(throws: refused) { try await provider.put(key, data: Data([1]), condition: .overwrite) }
    await #expect(throws: refused) { try await provider.listAll(prefix: "") }
    await #expect(throws: refused) { try await provider.get(key) }
    #expect(fake.zoneExists == false)
    #expect(fake.callCount(.ensureZone) == 1)
    try await provider.recreateZone()
    #expect(try await provider.condition() == nil)
    #expect(try await CloudKitFixture.keys(provider).isEmpty)
    _ = try await provider.put(key, data: Data([2]), condition: .ifAbsent)
    #expect(try await CloudKitFixture.keys(provider) == ["a"])
  }

  @Test("should treat a zone that vanished without an event as lost on the next call", arguments: [CloudKitZoneLoss.missing, .purged])
  func detectsSilentZoneLoss(loss: CloudKitZoneLoss) async throws {
    let fake = FakeCloudKitZone()
    let store = InMemoryCloudKitStateStore()
    let provider = CloudKitFixture.provider(fake, store: store)
    let conditions = provider.conditionChanges()
    _ = try await provider.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    fake.deleteZone(loss, notify: false)
    await #expect(throws: StorageError.unavailable(loss.explanation)) { try await provider.put(try CloudKitFixture.key("b"), data: Data([1]), condition: .overwrite) }
    #expect(await CloudKitFixture.first(conditions) == .zoneLost(loss))
    #expect(fake.zoneExists == false)
    #expect(await store.state?.zoneStatus == .lost(loss))
    #expect(await store.state?.entries.isEmpty == true)
    let restarted = CloudKitFixture.provider(fake, store: store)
    #expect(try await restarted.condition() == .zoneLost(loss))
    await #expect(throws: StorageError.unavailable(loss.explanation)) { try await restarted.listAll(prefix: "") }
  }

  @Test("should treat a zone that vanished as lost when the feed reports it")
  func detectsLossInFeed() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    _ = try await provider.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    #expect(try await CloudKitFixture.keys(provider) == ["a"])
    fake.deleteZone(.missing, notify: false)
    await #expect(throws: StorageError.unavailable(CloudKitZoneLoss.missing.explanation)) { try await provider.listAll(prefix: "") }
    #expect(try await provider.condition() == .zoneLost(.missing))
  }

  @Test("should stop every call after a sign-out or an account switch, without uploading into the new account")
  func stopsOnAccountChange() async throws {
    let fake = FakeCloudKitZone()
    let store = InMemoryCloudKitStateStore()
    let provider = CloudKitFixture.provider(fake, store: store)
    let conditions = provider.conditionChanges()
    let key = try CloudKitFixture.key("a")
    _ = try await provider.put(key, data: Data([1]), condition: .overwrite)
    fake.signIn("user-2")
    let change = CloudKitAccountChange.switched(previous: "user-1", current: "user-2")
    #expect(await CloudKitFixture.first(conditions) == .accountChanged(change))
    let refused = CloudKitStorageCondition.accountChanged(change).error
    await #expect(throws: refused) { try await provider.put(try CloudKitFixture.key("b"), data: Data([1]), condition: .overwrite) }
    await #expect(throws: refused) { try await provider.listAll(prefix: "") }
    await #expect(throws: refused) { try await provider.recreateZone() }
    #expect(fake.zoneExists == false)
    #expect(fake.callCount(.ensureZone) == 1)
    #expect(await store.state?.accountChange == change)
  }

  @Test("should report a sign-out as unauthenticated and ignore a sign-in from no account")
  func handlesSignOutAndSignIn() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let conditions = provider.conditionChanges()
    _ = try await provider.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
    fake.signOut()
    #expect(await CloudKitFixture.first(conditions) == .accountChanged(.signedOut(previous: "user-1")))
    await #expect(throws: StorageError.unauthenticated) { try await provider.get(try CloudKitFixture.key("a")) }
    #expect(try await fake.accountStatus() == .noAccount)

    let fresh = FakeCloudKitZone()
    fresh.signOut()
    let waiting = CloudKitFixture.provider(fresh)
    await #expect(throws: StorageError.unauthenticated) { try await waiting.listAll(prefix: "") }
    let noticed = waiting.changeNotices()
    fresh.signIn("user-1")
    fresh.seed(try CloudKitFixture.record(path: "theirs", data: Data([1])))
    fresh.pushHint()
    #expect(await CloudKitFixture.first(noticed) != nil)
    #expect(try await waiting.condition() == nil)
    _ = try await waiting.put(try CloudKitFixture.key("a"), data: Data([1]), condition: .overwrite)
  }
}
