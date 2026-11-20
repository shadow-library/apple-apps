import Foundation
import ShadowCore
import ShadowKeychain
import ShadowSync
import ShadowSyncRuntime
import ShadowTestSupport
import Synchronization
import Testing

@Suite("VaultSetup", TestTimeLimit.quick)
struct VaultSetupTests {
  private static let mine = RuntimeFixture.vault("vault-mine")
  private static let theirs = RuntimeFixture.vault("vault-theirs")

  private static func setup(_ provider: any StorageProvider, ring: any SecureStore, vault: VaultID = mine) -> VaultSetup {
    VaultSetup(provider: provider, ringStore: ring, makeVaultID: { vault }, makeKeyID: { RuntimeFixture.keyID(1) })
  }

  private static func object(_ text: String) throws -> ObjectKey {
    try #require(ObjectKey(text))
  }

  private static func putManifest(of vault: VaultID, in provider: any StorageProvider) async throws {
    let replica = ReplicaID(UUID.v7())
    let key = VaultKey.generate(id: RuntimeFixture.keyID(9))
    let path = VaultPath.manifest(replica)
    _ = try await provider.put(path, data: try VaultFile.seal(Data("{}".utf8), path: path.rawValue, vault: vault, key: key), condition: .overwrite)
  }

  @Test("should find nothing in an empty location or one holding only foreign objects")
  func discoversEmpty() async throws {
    let provider = InMemoryStorageProvider()
    let setup = Self.setup(provider, ring: InMemorySecureStore())
    #expect(try await setup.discover() == .empty)

    _ = try await provider.put(try Self.object(".shadow-s3-probe/conditional-writes"), data: Data(), condition: .overwrite)

    #expect(try await setup.discover() == .empty)
  }

  @Test("should find the vault named by the hint")
  func discoversHint() async throws {
    let provider = InMemoryStorageProvider()
    _ = try await provider.put(VaultPath.hint, data: VaultHint(vault: Self.theirs).encoded(), condition: .ifAbsent)

    #expect(try await Self.setup(provider, ring: InMemorySecureStore()).discover() == .found(Self.theirs))
  }

  @Test("should find the vault named by a manifest header when the hint is missing or unreadable")
  func discoversManifest() async throws {
    let provider = InMemoryStorageProvider()
    try await Self.putManifest(of: Self.theirs, in: provider)
    let setup = Self.setup(provider, ring: InMemorySecureStore())
    #expect(try await setup.discover() == .found(Self.theirs))

    _ = try await provider.put(VaultPath.hint, data: Data("garbage".utf8), condition: .overwrite)

    #expect(try await setup.discover() == .found(Self.theirs))
  }

  @Test("should not recognise vault files that name no vault and never create over them")
  func unrecognized() async throws {
    let provider = InMemoryStorageProvider()
    let ring = InMemorySecureStore()
    _ = try await provider.put(VaultPath.hint, data: Data("garbage".utf8), condition: .overwrite)
    let setup = Self.setup(provider, ring: ring)

    #expect(try await setup.discover() == .unrecognized)
    await #expect(throws: VaultSetupError.unrecognized) { try await setup.create() }
    #expect(try ring.allKeys().isEmpty)
  }

  @Test("should report a hint written in a newer format")
  func newerFormat() async throws {
    let provider = InMemoryStorageProvider()
    _ = try await provider.put(VaultPath.hint, data: Data(#"{"format":2,"vault":"vault-theirs"}"#.utf8), condition: .ifAbsent)
    let setup = Self.setup(provider, ring: InMemorySecureStore())

    #expect(try await setup.discover() == .newerFormat(2))
    await #expect(throws: VaultSetupError.newerFormat(2)) { try await setup.join(Self.theirs) }
  }

  @Test("should insert the ring key before the hint becomes visible")
  func keyBeforeHint() async throws {
    let ring = InMemorySecureStore()
    let keyHeld = Flag(false)
    let script = ScriptedProvider.Script(beforeHintPut: { _ in
      keyHeld.set((try? ring.allKeys()) == [KeyRing.itemName(vault: Self.mine, key: RuntimeFixture.keyID(1))])
    })
    let provider = ScriptedProvider(script: script)

    let creation = try await Self.setup(provider, ring: ring).create()

    #expect(creation == .created(Self.mine, key: RuntimeFixture.keyID(1)))
    #expect(keyHeld.isSet)
    #expect(try await RuntimeFixture.hint(in: provider) == Self.mine)
  }

  @Test("should join a vault that is already here without creating a key")
  func createJoinsExisting() async throws {
    let provider = InMemoryStorageProvider()
    let ring = InMemorySecureStore()
    _ = try await provider.put(VaultPath.hint, data: VaultHint(vault: Self.theirs).encoded(), condition: .ifAbsent)

    #expect(try await Self.setup(provider, ring: ring).create() == .joined(Self.theirs))
    #expect(try ring.allKeys().isEmpty)
  }

  @Test("should join the winner when another device puts its hint first, leaving its own key unused")
  func lostRace() async throws {
    let ring = InMemorySecureStore()
    let provider = ScriptedProvider(
      script: ScriptedProvider.Script(beforeHintPut: { inner in
        _ = try? await inner.put(VaultPath.hint, data: VaultHint(vault: Self.theirs).encoded(), condition: .ifAbsent)
      }))

    let creation = try await Self.setup(provider, ring: ring).create()

    #expect(creation == .joined(Self.theirs))
    #expect(try await RuntimeFixture.hint(in: provider) == Self.theirs)
    #expect(try ring.allKeys() == [KeyRing.itemName(vault: Self.mine, key: RuntimeFixture.keyID(1))])
  }

  @Test("should count a put whose acknowledgement was lost as created")
  func lostAcknowledgement() async throws {
    let provider = ScriptedProvider(script: ScriptedProvider.Script(failingPuts: 1, writesBeforeFailing: true))

    #expect(try await Self.setup(provider, ring: InMemorySecureStore()).create() == .created(Self.mine, key: RuntimeFixture.keyID(1)))
  }

  @Test("should fail without a visible vault when the put fails, and create on the next try")
  func failedPut() async throws {
    let provider = ScriptedProvider(script: ScriptedProvider.Script(failingPuts: 1))
    let ring = InMemorySecureStore()

    await #expect(throws: VaultSetupError.storage(.unavailable("scripted failure"))) { try await Self.setup(provider, ring: ring).create() }
    #expect(try await RuntimeFixture.hint(in: provider) == nil)

    let second = RuntimeFixture.vault("vault-second")
    #expect(try await Self.setup(provider, ring: ring, vault: second).create() == .created(second, key: RuntimeFixture.keyID(1)))
    #expect(try ring.allKeys().count == 2)
  }

  @Test("should join the vault written over its hint on a provider without atomic put-if-absent")
  func nonAtomicOverwrite() async throws {
    let script = ScriptedProvider.Script(
      supportsPutIfAbsent: false,
      afterHintPut: { inner in
        _ = try? await inner.put(VaultPath.hint, data: VaultHint(vault: Self.theirs).encoded(), condition: .overwrite)
      })

    #expect(try await Self.setup(ScriptedProvider(script: script), ring: InMemorySecureStore()).create() == .joined(Self.theirs))
  }

  @Test("should write nothing when the keychain is locked")
  func lockedKeychain() async throws {
    let provider = InMemoryStorageProvider()

    await #expect(throws: VaultSetupError.deviceLocked) { try await Self.setup(provider, ring: LockedSecureStore()).create() }
    #expect(provider.callCounts.put == 0)
  }

  @Test("should write nothing when cancelled before creating")
  func cancelled() async throws {
    let provider = InMemoryStorageProvider()
    let ring = InMemorySecureStore()
    let setup = Self.setup(provider, ring: ring)

    let result = await Task { () -> Result<VaultCreation, VaultSetupError> in
      withUnsafeCurrentTask { $0?.cancel() }
      do throws(VaultSetupError) {
        return .success(try await setup.create())
      } catch {
        return .failure(error)
      }
    }.value

    #expect(result == .failure(.cancelled))
    #expect(try ring.allKeys().isEmpty)
    #expect(provider.callCounts.put == 0)
  }

  @Test("should join only the vault the hint names")
  func join() async throws {
    let provider = InMemoryStorageProvider()
    let setup = Self.setup(provider, ring: InMemorySecureStore())
    await #expect(throws: VaultSetupError.vaultNotFound(Self.theirs)) { try await setup.join(Self.theirs) }
    _ = try await provider.put(VaultPath.hint, data: VaultHint(vault: Self.theirs).encoded(), condition: .ifAbsent)

    #expect(try await setup.join(Self.theirs) == Self.theirs)
    await #expect(throws: VaultSetupError.vaultMismatch(expected: Self.mine, found: Self.theirs)) { try await setup.join(Self.mine) }
  }
}
