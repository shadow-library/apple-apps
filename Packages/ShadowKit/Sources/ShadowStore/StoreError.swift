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
