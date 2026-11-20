import Foundation
import GRDB

import ShadowCore

public enum StoreError: ShadowError {
  case database(String)
  case invalidChange(String)
  case changeTooLarge(Int)
  case unknownRevision(String)
  case entityPurged(EntityRef)
  case duplicateMigration(String)
  case corruptStore(String)
  case replicaReused(ReplicaID)
  case registryDowngrade(stored: Int, current: Int)
  case sequenceExhausted
  case aborted(any Error)
  case clockAhead(HLCTimestamp)
  case replicaCollision(ReplicaID)
  case incompatibleRegistry(String)
  case reconcilerFailed(any Error)
  case fileProtection(path: String, reason: String)
  case backupExclusion(path: String, reason: String)
  case backupExclusionPinned
  case syncClassNotAdmitted(kind: EntityKind, syncClass: SyncClass)
  case processLock(path: String, reason: String)

  public var code: String {
    switch self {
    case .database: "store.database"
    case .invalidChange: "store.invalid_change"
    case .changeTooLarge: "store.change_too_large"
    case .unknownRevision: "store.unknown_revision"
    case .entityPurged: "store.entity_purged"
    case .duplicateMigration: "store.duplicate_migration"
    case .corruptStore: "store.corrupt_store"
    case .replicaReused: "store.replica_reused"
    case .registryDowngrade: "store.registry_downgrade"
    case .sequenceExhausted: "store.sequence_exhausted"
    case .aborted: "store.aborted"
    case .clockAhead: "store.clock_ahead"
    case .replicaCollision: "store.replica_collision"
    case .incompatibleRegistry: "store.incompatible_registry"
    case .reconcilerFailed: "store.reconciler_failed"
    case .fileProtection: "store.file_protection"
    case .backupExclusion: "store.backup_exclusion"
    case .backupExclusionPinned: "store.backup_exclusion_pinned"
    case .syncClassNotAdmitted: "store.sync_class_not_admitted"
    case .processLock: "store.process_lock"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .database(let message): "Database failure: \(message)"
    case .invalidChange(let reason): "Invalid change: \(reason)."
    case .changeTooLarge(let size): "Change of \(size) bytes exceeds the limit of \(VaultStore.maximumChangeBytes) bytes."
    case .unknownRevision(let revision): "Revision \(revision) is not in the store."
    case .entityPurged(let ref): "\(ref.kind)/\(ref.key) is purged."
    case .duplicateMigration(let identifier): "Migration \(identifier) is registered twice."
    case .corruptStore(let reason): "The store is corrupt: \(reason)."
    case .replicaReused(let replica): "Replica \(replica) is the current replica and cannot be minted again."
    case .registryDowngrade(let stored, let current): "The store was last opened with registry version \(stored), newer than version \(current)."
    case .sequenceExhausted: "The change log has used every sequence number."
    case .aborted(let error): "The transaction was aborted: \(error.localizedDescription)"
    case .clockAhead(let clock): "A remote change is stamped \(clock), beyond the limit the reader accepts."
    case .replicaCollision(let replica): "A remote change carries this store's replica id \(replica), so another writer is using it."
    case .incompatibleRegistry(let reason): "The registry cannot carry the stored state additively: \(reason)."
    case .reconcilerFailed(let error): "The reconciler failed: \(error.localizedDescription)"
    case .fileProtection(let path, let reason): "File protection could not be applied to \(path): \(reason)."
    case .backupExclusion(let path, let reason): "Backup exclusion could not be changed on \(path): \(reason)."
    case .backupExclusionPinned: "The store is always excluded from device backups; the exclusion cannot be cleared."
    case .syncClassNotAdmitted(let kind, let syncClass): "Kind \(kind) is in sync class \(syncClass.rawValue), which this store does not admit."
    case .processLock(let path, let reason): "The process lock \(path) could not be taken: \(reason)."
    }
  }
}

extension StoreError {
  init(converting error: any Error) {
    switch error {
    case let error as StoreError: self = error
    case let error as DatabaseError: self = .database("SQLite error \(error.extendedResultCode.rawValue): \(error.message ?? "no message")")
    default: self = .aborted(error)
    }
  }

  static func wrapping<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(converting: error)
    }
  }
}
