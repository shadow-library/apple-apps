import Foundation
import OSLog
import ShadowCore
import ShadowKeychain
import ShadowSync

/// Finds, creates and joins the vault at one storage location. A vault becomes visible only through its hint, and the hint is put only after the
/// ring key is in the keychain, so no device ever sees a vault whose creator holds no key. A device never creates a key for a vault it did not create.
public struct VaultSetup: Sendable {
  private static let logger = Logger(category: "VaultSetup")

  private enum HintRead {
    case hint(VaultID)
    case absent
    case newerFormat(Int64)
    case unreadable
  }

  public let provider: any StorageProvider
  private let ringStore: any SecureStore
  private let makeVaultID: @Sendable () -> VaultID
  private let makeKeyID: @Sendable () -> KeyID

  public init(
    provider: any StorageProvider, ringStore: any SecureStore, makeVaultID: @escaping @Sendable () -> VaultID = VaultSetup.newVaultID,
    makeKeyID: @escaping @Sendable () -> KeyID = { KeyID(UUID.v7()) }
  ) {
    self.provider = provider
    self.ringStore = ringStore
    self.makeVaultID = makeVaultID
    self.makeKeyID = makeKeyID
  }

  public static func newVaultID() -> VaultID {
    guard let vault = VaultID(UUID.v7().uuidString.lowercased()) else { preconditionFailure("a lower-case UUID is a vault id") }
    return vault
  }

  public func discover() async throws(VaultSetupError) -> VaultDiscovery {
    switch try await readHint() {
    case .hint(let vault): return .found(vault)
    case .newerFormat(let format): return .newerFormat(format)
    case .absent, .unreadable: return try await scanForVault()
    }
  }

  /// Joins the vault already here instead of creating one; a lost put-if-absent race joins the winner and leaves this device's new key unused.
  public func create() async throws(VaultSetupError) -> VaultCreation {
    switch try await discover() {
    case .found(let vault): return .joined(vault)
    case .newerFormat(let format): throw .newerFormat(format)
    case .unrecognized: throw .unrecognized
    case .empty: break
    }
    guard !Task.isCancelled else { throw .cancelled }
    let vault = makeVaultID()
    let key: VaultKey
    do {
      key = try KeyRing(vault: vault, store: ringStore, makeKeyID: makeKeyID).createKey()
    } catch {
      throw VaultSetupError(keyRing: error)
    }
    do {
      _ = try await provider.put(VaultPath.hint, data: VaultHint(vault: vault).encoded(), condition: .ifAbsent)
    } catch {
      return try await settle(afterFailedPut: error, vault: vault, key: key.id)
    }
    guard !provider.capabilities.supportsPutIfAbsent, case .hint(let written)? = try? await readHint(), written != vault else {
      Self.logger.info("Created a vault vault=\(vault.rawValue, privacy: .private)")
      return .created(vault, key: key.id)
    }
    Self.logger.info("Joined a vault written over this device's hint vault=\(written.rawValue, privacy: .private)")
    return .joined(written)
  }

  public func join(_ vault: VaultID) async throws(VaultSetupError) -> VaultID {
    switch try await discover() {
    case .found(let found) where found == vault: return vault
    case .found(let found): throw .vaultMismatch(expected: vault, found: found)
    case .empty: throw .vaultNotFound(vault)
    case .newerFormat(let format): throw .newerFormat(format)
    case .unrecognized: throw .unrecognized
    }
  }

  private func settle(afterFailedPut failure: StorageError, vault: VaultID, key: KeyID) async throws(VaultSetupError) -> VaultCreation {
    let lostRace: Bool
    switch failure {
    case .alreadyExists, .keyConflict: lostRace = true
    default: lostRace = false
    }
    let read: HintRead
    do {
      read = try await readHint()
    } catch {
      throw lostRace ? error : .storage(failure)
    }
    switch read {
    case .hint(let found) where found == vault: return .created(vault, key: key)
    case .hint(let found):
      Self.logger.info("Lost the race to create a vault; joining vault=\(found.rawValue, privacy: .private)")
      return .joined(found)
    case .newerFormat(let format): throw .newerFormat(format)
    case .unreadable: throw .unrecognized
    case .absent: throw .storage(failure)
    }
  }

  private func readHint() async throws(VaultSetupError) -> HintRead {
    let data: Data
    do {
      data = try await provider.get(VaultPath.hint)
    } catch {
      guard case .notFound = error else { throw .storage(error) }
      return .absent
    }
    do {
      return .hint(try VaultHint(decoding: data).vault)
    } catch {
      guard case .unsupportedFormat(let format) = error else { return .unreadable }
      return .newerFormat(format)
    }
  }

  /// Objects the vault layout does not name, such as an S3 probe, never make a location count as holding a vault. A listed hint is read again:
  /// another device may have created the vault since the first read.
  private func scanForVault() async throws(VaultSetupError) -> VaultDiscovery {
    var sawVaultObject = false
    var cursor: ListCursor?
    repeat {
      let page: ListPage
      do {
        page = try await provider.list(prefix: "", after: cursor)
      } catch {
        throw .storage(error)
      }
      guard page.next == nil || page.next != cursor else { throw .storage(.underlying("list cursor did not advance")) }
      for object in page.objects {
        let classified = VaultPath.classify(object.key)
        if classified == .unknown { continue }
        if classified == .hint {
          switch try await readHint() {
          case .hint(let vault): return .found(vault)
          case .newerFormat(let format): return .newerFormat(format)
          case .absent: continue
          case .unreadable: break
          }
        }
        sawVaultObject = true
        guard case .manifest = classified, let vault = try await vaultNamed(byManifest: object.key) else { continue }
        return .found(vault)
      }
      cursor = page.next
    } while cursor != nil
    return sawVaultObject ? .unrecognized : .empty
  }

  private func vaultNamed(byManifest key: ObjectKey) async throws(VaultSetupError) -> VaultID? {
    let data: Data
    do {
      data = try await provider.get(key)
    } catch {
      guard case .notFound = error else { throw .storage(error) }
      return nil
    }
    return try? VaultFile.header(of: data).vault
  }
}
