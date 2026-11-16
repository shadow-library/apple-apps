import Foundation
import ShadowCore
import ShadowStore

public enum ReplicaLifecycleError: ShadowError {
  case markerUnavailable
  case marker(ReplicaFileError)
  case store(StoreError)
  case bootstrapRequired
  case retiringCurrentReplica(ReplicaID)
  case replicaReused(ReplicaID)
  case concurrentChange
  case corruptState(String)

  public var code: String {
    switch self {
    case .markerUnavailable: "replica-lifecycle.marker-unavailable"
    case .marker(let error): error.code
    case .store(let error): error.code
    case .bootstrapRequired: "replica-lifecycle.bootstrap-required"
    case .retiringCurrentReplica: "replica-lifecycle.retiring-current-replica"
    case .replicaReused: "replica-lifecycle.replica-reused"
    case .concurrentChange: "replica-lifecycle.concurrent-change"
    case .corruptState: "replica-lifecycle.corrupt-state"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .markerUnavailable: "The device marker cannot be read yet. Try again once the device is unlocked."
    case .marker(let error): error.errorDescription
    case .store(let error): error.errorDescription
    case .bootstrapRequired: "The replica has not finished starting up on this device."
    case .retiringCurrentReplica(let replica): "Replica \(replica) is the one this device writes as; it is replaced by re-minting, not retired."
    case .replicaReused(let replica): "Replica \(replica) has already been used by this database."
    case .concurrentChange: "Another replica operation changed this database at the same time."
    case .corruptState(let reason): "The replica bookkeeping is corrupt: \(reason)."
    }
  }

  init(converting error: StoreError) {
    guard case .aborted(let underlying) = error, let lifecycle = underlying as? ReplicaLifecycleError else {
      self = .store(error)
      return
    }
    self = lifecycle
  }
}
