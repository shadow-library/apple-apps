import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The sealed copies of ring keys under `keys/`, kept in step with the vault's recovery records. This device records every (recipient, key) pair it
/// has sealed or deleted and acts on each pair once, so a listing that lacks a copy never makes it seal again: a device whose records are stale would
/// otherwise put back the copies of a replaced, possibly leaked, phrase. Copies are deleted only under names built from the recipients the vault
/// records and the keys the ring holds, never from a listing.
public struct RecoveryCopies: Sendable {
  private enum Mark: String {
    case sealed
    case deleted
  }

  public static let migration = StoreMigration(identifier: "com.shadow.library.shadowsync.recovery-copies.1") { db in
    try db.execute(
      sql: """
        CREATE TABLE sync_recovery_copy (
          recipient TEXT NOT NULL,
          key TEXT NOT NULL,
          mark TEXT NOT NULL CHECK (mark IN ('\(Mark.sealed.rawValue)', '\(Mark.deleted.rawValue)')),
          PRIMARY KEY (recipient, key)
        ) STRICT, WITHOUT ROWID;
        """)
  }

  public let store: VaultStore
  public let provider: any StorageProvider
  public let ring: KeyRing

  /// `store` must have been opened with `SyncEngine.migrations`.
  public init(store: VaultStore, provider: any StorageProvider, ring: KeyRing) {
    self.store = store
    self.provider = provider
    self.ring = ring
  }

  public var vault: VaultID { ring.vault }

  /// Puts a copy of each of `keyIDs` that the ring holds and this device has neither sealed nor deleted for `recipient` before.
  public func seal(_ keyIDs: [KeyID], to recipient: RecoveryRecipient) async throws(RecoveryCopiesError) -> [KeyID] {
    let marked = try await marks(of: recipient.id)
    var sealed: [KeyID] = []
    for keyID in keyIDs where marked[keyID] == nil {
      guard let key = ring.key(keyID) else { continue }
      let data: Data
      do {
        data = try SealedRingKey.seal(key, to: recipient, vault: vault)
      } catch {
        throw .envelope(error)
      }
      do {
        _ = try await provider.put(VaultPath.sealedKey(recipient: recipient.id, key: keyID), data: data, condition: .overwrite)
      } catch {
        throw .storage(error)
      }
      try await mark([(recipient.id, keyID)], .sealed)
      sealed.append(keyID)
    }
    return sealed
  }

  /// Seals the ring to the recipient the vault names when this is called.
  public func sealToActive() async throws(RecoveryCopiesError) -> [KeyID] {
    guard let active = try await directory().recovery else { return [] }
    return try await seal(ring.keyIDs, to: active)
  }

  /// Deletes the copies of ring keys under every recipient the vault records that is not the active one, once per pair.
  public func deleteInactive() async throws(RecoveryCopiesError) -> [ObjectKey] {
    let directory = try await directory()
    var inactive = Set(directory.recoveries.map(\.recipientID))
    if let active = directory.recovery { inactive.remove(active.id) }
    let ringKeys = ring.keyIDs
    var pairs: [(recipient: String, key: KeyID)] = []
    for recipient in inactive.sorted() {
      let marked = try await marks(of: recipient)
      pairs += ringKeys.filter { marked[$0] != .deleted }.map { (recipient, $0) }
    }
    guard !pairs.isEmpty else { return [] }
    let names = pairs.map { VaultPath.sealedKey(recipient: $0.recipient, key: $0.key) }
    do {
      try await provider.delete(names)
    } catch {
      throw .storage(error)
    }
    try await mark(pairs, .deleted)
    return names
  }

  private func directory() async throws(RecoveryCopiesError) -> ReplicaDirectory {
    do {
      return try await store.read { transaction in try ReplicaDirectory.read(in: transaction) }
    } catch {
      throw .store(error.code)
    }
  }

  private func marks(of recipient: String) async throws(RecoveryCopiesError) -> [KeyID: Mark] {
    do {
      return try await store.read { transaction in
        var marks: [KeyID: Mark] = [:]
        for row in try Row.fetchAll(transaction.database, sql: "SELECT key, mark FROM sync_recovery_copy WHERE recipient = ?", arguments: [recipient]) {
          guard let key = (row["key"] as String?).flatMap(KeyID.init), let mark = (row["mark"] as String?).flatMap(Mark.init(rawValue:)) else { continue }
          marks[key] = mark
        }
        return marks
      }
    } catch {
      throw .store(error.code)
    }
  }

  private func mark(_ pairs: [(recipient: String, key: KeyID)], _ mark: Mark) async throws(RecoveryCopiesError) {
    let rows = pairs.map { [$0.recipient, $0.key.description] }
    do {
      try await store.write { transaction in
        for row in rows {
          try transaction.database.execute(
            sql: "INSERT INTO sync_recovery_copy (recipient, key, mark) VALUES (?, ?, ?) ON CONFLICT (recipient, key) DO UPDATE SET mark = excluded.mark",
            arguments: [row[0], row[1], mark.rawValue])
        }
      }
    } catch {
      throw .store(error.code)
    }
  }
}

public enum RecoveryCopiesError: ShadowError, Equatable {
  case storage(StorageError)
  case store(String)
  case envelope(KeyEnvelopeError)

  public var code: String {
    switch self {
    case .storage(let error): error.code
    case .store: "recovery-copies.store"
    case .envelope(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .storage(let error): error.errorDescription
    case .store(let reason): "The record of sealed recovery copies could not be read or written (\(reason))."
    case .envelope(let error): error.errorDescription
    }
  }
}
