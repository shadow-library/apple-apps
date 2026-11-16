import Foundation
import ShadowCore
import ShadowKeychain
import ShadowTestSupport
import Testing

@testable import ShadowSync

private struct DeviceMarkerFailingStore: SecureStore {
  func data(forKey key: String) throws(SecureStoreError) -> Data? { throw .unexpectedStatus(-25308) }
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { throw .unexpectedStatus(-25308) }
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { throw .unexpectedStatus(-25308) }
  func removeValue(forKey key: String) throws(SecureStoreError) { throw .unexpectedStatus(-25308) }
  func allKeys() throws(SecureStoreError) -> [String] { throw .unexpectedStatus(-25308) }
}

private func deviceMarkerReplica(_ text: String) -> ReplicaID {
  guard let replica = ReplicaID(text) else { preconditionFailure("fixture replica id is valid") }
  return replica
}

@Suite("DeviceMarker")
struct DeviceMarkerTests {
  private let replicaA = deviceMarkerReplica("01936f3e-1111-7111-8111-111111111111")
  private let replicaB = deviceMarkerReplica("01936f3e-2222-7222-8222-222222222222")

  private func store(_ keychain: InMemoryKeychain = InMemoryKeychain(), device: String = "phone") -> any SecureStore {
    keychain.device(device).store(service: "marker", scope: .device)
  }

  @Test("should name the item after the vault")
  func shouldNameItem() throws {
    #expect(DeviceMarker.itemName(vault: try CodecFixtures.vault("vault-one")) == "replica-marker/vault-one")
  }

  @Test("should report a missing marker, then match after a claim")
  func shouldClaim() throws {
    let marker = DeviceMarker(store: store())
    let vault = try CodecFixtures.vault()
    #expect(marker.status(vault: vault, replica: replicaA) == .missing)
    try marker.claim(vault: vault, replica: replicaA)
    #expect(marker.status(vault: vault, replica: replicaA) == .matches)
  }

  @Test("should name the other replica when the marker differs")
  func shouldNameOther() throws {
    let marker = DeviceMarker(store: store())
    let vault = try CodecFixtures.vault()
    try marker.claim(vault: vault, replica: replicaB)
    #expect(marker.status(vault: vault, replica: replicaA) == .other(replicaB))
    try marker.claim(vault: vault, replica: replicaA)
    #expect(marker.status(vault: vault, replica: replicaA) == .matches)
  }

  @Test(
    "should treat garbage values as unreadable",
    arguments: [
      Data("not a replica id".utf8),
      Data(),
      Data([0xFF, 0xFE, 0x00]),
      Data("01936F3E-1111-7111-8111-111111111111".utf8),
      Data(" 01936f3e-1111-7111-8111-111111111111".utf8),
    ])
  func shouldRejectGarbage(value: Data) throws {
    let backing = store()
    let vault = try CodecFixtures.vault()
    try backing.setData(value, forKey: DeviceMarker.itemName(vault: vault))
    #expect(DeviceMarker(store: backing).status(vault: vault, replica: replicaA) == .unreadable)
  }

  @Test("should treat a failing store as unreadable and fail writes without a secret")
  func shouldSurviveStoreFailure() throws {
    let marker = DeviceMarker(store: DeviceMarkerFailingStore())
    let vault = try CodecFixtures.vault()
    #expect(marker.status(vault: vault, replica: replicaA) == .unreadable)
    #expect(throws: ReplicaFileError.keychain("secure_store.unexpected_status -25308")) { try marker.claim(vault: vault, replica: replicaA) }
    #expect(throws: ReplicaFileError.keychain("secure_store.unexpected_status -25308")) { try marker.clear(vault: vault) }
  }

  @Test("should repair an unreadable marker")
  func shouldRepair() throws {
    let backing = store()
    let vault = try CodecFixtures.vault()
    let marker = DeviceMarker(store: backing)
    try backing.setData(Data("garbage".utf8), forKey: DeviceMarker.itemName(vault: vault))
    #expect(marker.status(vault: vault, replica: replicaA) == .unreadable)
    try marker.repair(vault: vault, replica: replicaA)
    #expect(marker.status(vault: vault, replica: replicaA) == .matches)
  }

  @Test("should not repair a marker that names another replica")
  func shouldNotRepairForeignMarker() throws {
    let backing = store()
    let vault = try CodecFixtures.vault()
    let marker = DeviceMarker(store: backing)
    try marker.claim(vault: vault, replica: replicaB)
    #expect(throws: ReplicaFileError.markerNotRepairable) { try marker.repair(vault: vault, replica: replicaA) }
    #expect(marker.status(vault: vault, replica: replicaA) == .other(replicaB))
  }

  @Test("should not repair a missing marker")
  func shouldNotRepairMissingMarker() throws {
    let marker = DeviceMarker(store: store())
    let vault = try CodecFixtures.vault()
    #expect(throws: ReplicaFileError.markerNotRepairable) { try marker.repair(vault: vault, replica: replicaA) }
    #expect(marker.status(vault: vault, replica: replicaA) == .missing)
  }

  @Test("should not repair a marker that already matches")
  func shouldNotRepairMatchingMarker() throws {
    let marker = DeviceMarker(store: store())
    let vault = try CodecFixtures.vault()
    try marker.claim(vault: vault, replica: replicaA)
    #expect(throws: ReplicaFileError.markerNotRepairable) { try marker.repair(vault: vault, replica: replicaA) }
    #expect(marker.status(vault: vault, replica: replicaA) == .matches)
  }

  @Test("should report a keychain error when the read fails during repair")
  func shouldFailRepair() throws {
    let vault = try CodecFixtures.vault()
    #expect(throws: ReplicaFileError.keychain("secure_store.unexpected_status -25308")) {
      try DeviceMarker(store: DeviceMarkerFailingStore()).repair(vault: vault, replica: replicaA)
    }
  }

  @Test("should clear the marker")
  func shouldClear() throws {
    let marker = DeviceMarker(store: store())
    let vault = try CodecFixtures.vault()
    try marker.claim(vault: vault, replica: replicaA)
    try marker.clear(vault: vault)
    #expect(marker.status(vault: vault, replica: replicaA) == .missing)
    try marker.clear(vault: vault)
  }

  @Test("should keep two vaults apart")
  func shouldSeparateVaults() throws {
    let marker = DeviceMarker(store: store())
    let one = try CodecFixtures.vault("vault-one")
    let two = try CodecFixtures.vault("vault-two")
    try marker.claim(vault: one, replica: replicaA)
    try marker.claim(vault: two, replica: replicaB)
    #expect(marker.status(vault: one, replica: replicaA) == .matches)
    #expect(marker.status(vault: two, replica: replicaA) == .other(replicaB))
    try marker.clear(vault: one)
    #expect(marker.status(vault: two, replica: replicaB) == .matches)
  }

  @Test("should not reach a second device")
  func shouldStayOnTheDevice() throws {
    let keychain = InMemoryKeychain()
    let vault = try CodecFixtures.vault()
    try DeviceMarker(store: store(keychain, device: "phone")).claim(vault: vault, replica: replicaA)
    keychain.deliver()
    #expect(DeviceMarker(store: store(keychain, device: "laptop")).status(vault: vault, replica: replicaA) == .missing)
    #expect(DeviceMarker(store: store(keychain, device: "phone")).status(vault: vault, replica: replicaA) == .matches)
  }
}
