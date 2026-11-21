import Foundation
import OSLog
import ShadowCore
import ShadowSync

/// Brings a vault's keys to a device from the recovery phrase. The recipient is derived from the phrase and the vault id, so a phrase used on
/// another vault, or a hint that names another vault, finds no copies. A copy joins the ring only after it authenticates under the phrase's
/// pre-shared key, which no storage provider holds, sits under its own key's name, and its key opens a file at this location; that last check refuses
/// a key that opens nothing here and adds no authenticity.
public struct PhraseRecovery: Sendable {
  private static let logger = Logger(category: "PhraseRecovery")

  public let provider: any StorageProvider
  public let ring: KeyRing

  public init(provider: any StorageProvider, ring: KeyRing) {
    self.provider = provider
    self.ring = ring
  }

  public var vault: VaultID { ring.vault }

  public func recover(_ phrase: RecoveryPhrase) async throws(RecoveryError) -> KeyImport {
    let recovery = RecoveryKey(secret: phrase.secret, vault: vault)
    let recipientID = recovery.recipient.id
    do {
      try ring.refresh()
    } catch {
      throw RecoveryError(error)
    }
    let files: HeldFiles
    let listed: Set<KeyID>
    do {
      files = try await HeldFiles.survey(provider, vault: vault)
      listed = try await provider.listedCopies(of: recipientID)
    } catch {
      throw .storage(error)
    }
    var found = 0
    var opened: [VaultKey] = []
    for keyID in listed.union(files.namedKeys).sorted() {
      let path = VaultPath.sealedKey(recipient: recipientID, key: keyID)
      let sealed: Data?
      do {
        sealed = try await provider.getIfPresent(path)
      } catch {
        throw .storage(error)
      }
      guard let sealed else { continue }
      found += 1
      guard let key = try? SealedRingKey.open(sealed, with: recovery, vault: vault), key.id == keyID else {
        Self.logger.warning("Refused a sealed key copy key=\(keyID, privacy: .public)")
        continue
      }
      opened.append(key)
    }
    guard found > 0 else { throw .noRecoveryCopies }
    guard !opened.isEmpty else { throw .recoveryCopiesRefused }
    let sorted = KeyAdmission.sort(opened, against: ring)
    let confirmed: Set<KeyID>
    do {
      confirmed = try await files.confirm(sorted.candidates)
    } catch {
      throw .storage(error)
    }
    let result: KeyImport
    do {
      result = try KeyAdmission.admit(sorted, confirmed: confirmed, to: ring)
    } catch {
      throw RecoveryError(error)
    }
    Self.logger.info("Recovered keys with the phrase added=\(result.added.count, privacy: .public) unconfirmed=\(result.unconfirmed.count, privacy: .public)")
    guard result.holdsAnyKey || result.unconfirmed.isEmpty else { throw .keysUnconfirmed(result.unconfirmed) }
    return result
  }
}
