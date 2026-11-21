import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("RecoveryCopies", TestTimeLimit.quick)
struct RecoveryCopiesTests {
  private static let vault = VaultID("vault-copies")

  private static func copies(_ provider: InMemoryStorageProvider, keys: [VaultKey]) throws -> RecoveryCopies {
    let vault = try #require(Self.vault)
    let store = try VaultStore.open(.inMemory, registry: ReplicaFixture.registry, migrations: SyncEngine.migrations, wallClock: { ReplicaFixture.start })
    let ring = KeyRing(vault: vault, store: InMemorySecureStore())
    for key in keys { try ring.add(key) }
    return RecoveryCopies(store: store, provider: provider, ring: ring)
  }

  private static func key(_ suffix: String) throws -> VaultKey {
    VaultKey.generate(id: try #require(KeyID("01936f3e-0000-7000-8000-\(suffix)")))
  }

  private static func listed(_ provider: InMemoryStorageProvider) async throws -> [String] {
    try await provider.listAll(prefix: "keys/").map(\.key.rawValue)
  }

  @Test("should seal each pair once, even when the copy has gone from the location since")
  func sealsOnce() async throws {
    let provider = InMemoryStorageProvider()
    let (first, second) = (try Self.key("000000000001"), try Self.key("000000000002"))
    let copies = try Self.copies(provider, keys: [first, second])
    let recipient = RecoveryKey(secret: .generate(), vault: copies.vault).recipient

    #expect(try await copies.seal([first.id], to: recipient) == [first.id])
    #expect(try await copies.seal([first.id, second.id], to: recipient) == [second.id])
    try await provider.delete([VaultPath.sealedKey(recipient: recipient.id, key: first.id)])

    #expect(try await copies.seal([first.id, second.id], to: recipient).isEmpty)
    #expect(try await Self.listed(provider) == [VaultPath.sealedKey(recipient: recipient.id, key: second.id).rawValue])
  }

  @Test("should delete only recorded inactive recipients' copies of ring keys, once")
  func deletesRecordedNames() async throws {
    let provider = InMemoryStorageProvider()
    let held = try Self.key("000000000001")
    let notHeld = try Self.key("000000000009")
    let copies = try Self.copies(provider, keys: [held])
    let (old, current) = (RecoveryKey(secret: .generate(), vault: copies.vault).recipient, RecoveryKey(secret: .generate(), vault: copies.vault).recipient)
    let unrecorded = RecoveryKey(secret: .generate(), vault: copies.vault).recipient
    for (recipient, key) in [(old, held), (old, notHeld), (unrecorded, held)] {
      _ = try await provider.put(
        VaultPath.sealedKey(recipient: recipient.id, key: key.id), data: try SealedRingKey.seal(key, to: recipient, vault: copies.vault), condition: .overwrite)
    }
    try await copies.store.write { transaction in
      try ReplicaDirectory.setRecovery(old, createdMillis: 1, in: &transaction)
      try ReplicaDirectory.retireRecovery(recipientID: old.id, in: &transaction)
      try ReplicaDirectory.setRecovery(current, createdMillis: 2, in: &transaction)
    }

    #expect(try await copies.deleteInactive() == [VaultPath.sealedKey(recipient: old.id, key: held.id)])
    #expect(try await copies.deleteInactive().isEmpty)
    #expect(try await copies.sealToActive() == [held.id])
    let expected = [
      VaultPath.sealedKey(recipient: old.id, key: notHeld.id), VaultPath.sealedKey(recipient: current.id, key: held.id),
      VaultPath.sealedKey(recipient: unrecorded.id, key: held.id),
    ].map(\.rawValue).sorted()
    #expect(try await Self.listed(provider) == expected)
  }
}
