import Foundation
import ShadowCore
import ShadowStore

public enum SyncError: ShadowError {
  case notStarted
  case store(StoreError)
  case storage(StorageError)
  case lifecycle(ReplicaLifecycleError)
  case codec(VaultCodecError)
  case replicaFile(ReplicaFileError)
  case keyRing(KeyRingError)
  case syncClassRefused(kind: EntityKind, syncClass: SyncClass?)
  case changeTooLarge(sequence: Int64, limit: Int)
  case baseTooLarge(limit: Int)
  case remintLimitReached(Int)
  case appUpdateRequired(minimumSchema: Int, current: Int)
  case storeClockUntrusted(skew: Duration)
  /// The database moved to another replica id during a call; the engine changes nothing under the new id and reports the call as postponed.
  case replicaChanged
  case corruptState(String)

  public var code: String {
    switch self {
    case .notStarted: "sync.not-started"
    case .store(let error): error.code
    case .storage(let error): error.code
    case .lifecycle(let error): error.code
    case .codec(let error): error.code
    case .replicaFile(let error): error.code
    case .keyRing(let error): error.code
    case .syncClassRefused: "sync.sync-class-refused"
    case .changeTooLarge: "sync.change-too-large"
    case .baseTooLarge: "sync.base-too-large"
    case .remintLimitReached: "sync.remint-limit-reached"
    case .appUpdateRequired: "sync.app-update-required"
    case .storeClockUntrusted: "sync.store-clock-untrusted"
    case .replicaChanged: "sync.replica-changed"
    case .corruptState: "sync.corrupt-state"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notStarted: "Sync has not started on this device yet."
    case .store(let error): error.errorDescription
    case .storage(let error): error.errorDescription
    case .lifecycle(let error): error.errorDescription
    case .codec(let error): error.errorDescription
    case .replicaFile(let error): error.errorDescription
    case .keyRing(let error): error.errorDescription
    case .syncClassRefused(let kind, let syncClass):
      "Changes to \(kind) (\(syncClass?.rawValue ?? "undeclared") class) may not be stored with this provider."
    case .changeTooLarge(let sequence, let limit): "Change \(sequence) does not fit in a file of at most \(limit) bytes."
    case .baseTooLarge(let limit): "A record of this device's base does not fit in a part of at most \(limit) bytes."
    case .remintLimitReached(let count): "The replica was re-minted \(count) times in one upload and still could not pass its checks."
    case .storeClockUntrusted(let skew): "The local store stamps changes with a clock \(skew) away from trusted time, so nothing is uploaded."
    case .appUpdateRequired(let minimum, let current):
      "The vault needs schema \(minimum) but this app writes schema \(current). Update the app to keep syncing; unsent changes are kept."
    case .replicaChanged: "This device's sync identity changed during the call, so the call stopped without changes."
    case .corruptState(let reason): "The sync bookkeeping is corrupt: \(reason)."
    }
  }

  init(converting error: StoreError) {
    guard case .aborted(let underlying) = error else {
      self = .store(error)
      return
    }
    switch underlying {
    case let error as SyncError: self = error
    case let error as ReplicaLifecycleError: self = .lifecycle(error)
    default: self = .store(error)
    }
  }

  init(converting error: ReplicaLifecycleError) {
    guard case .store(let store) = error else {
      self = .lifecycle(error)
      return
    }
    self.init(converting: store)
  }
}
