import ShadowSync
import ShadowSyncCloudKit
import ShadowSyncRuntime

extension SyncStatus {
  nonisolated var diagnosticsCode: String {
    switch self {
    case .off: "off"
    case .upToDate: "upToDate"
    case .syncing: "syncing"
    case .attentionNeeded: "attentionNeeded"
    }
  }

  nonisolated var attentionReason: SyncAttentionReason? {
    guard case .attentionNeeded(let reason) = self else { return nil }
    return reason
  }
}

/// Codes only: a vault id, a move notice's location and the replicas whose keys are missing are left out, the replicas counted.
extension SyncAttentionReason {
  nonisolated var diagnosticsCode: String {
    switch self {
    case .quotaFull: "quotaFull"
    case .accountUnavailable: "accountUnavailable"
    case .accountChanged: "accountChanged"
    case .storageRemoved: "storageRemoved"
    case .zoneLost(let loss): "zoneLost.\(loss.rawValue)"
    case .vaultMismatch: "vaultMismatch"
    case .vaultUnrecognized: "vaultUnrecognized"
    case .awaitingKey: "awaitingKey"
    case .writingKeyMissing: "writingKeyMissing"
    case .keysMissing: "keysMissing"
    case .wrongClock: "wrongClock"
    case .appUpdateRequired: "appUpdateRequired"
    case .deviceLocked: "deviceLocked"
    case .keychainUnavailable: "keychainUnavailable"
    case .settingsUnreadable: "settingsUnreadable"
    case .storageUnreachable: "storageUnreachable"
    case .vaultMoved: "vaultMoved"
    case .moveInProgress: "moveInProgress"
    case .failed: "failed"
    }
  }

  nonisolated var failureCode: String? {
    guard case .failed(let code) = self else { return nil }
    return code
  }

  nonisolated var replicasMissingKeys: Int? {
    guard case .keysMissing(let replicas) = self else { return nil }
    return replicas.count
  }

  nonisolated var clockSkewSeconds: Int? {
    guard case .wrongClock(let skew, _) = self else { return nil }
    return Int(skew.components.seconds)
  }
}

extension SyncStoppage {
  nonisolated var diagnosticsCode: String {
    switch self {
    case .everything: "everything"
    case .uploads: "uploads"
    case .downloads: "downloads"
    case .nothing: "nothing"
    }
  }
}

extension SyncPhase {
  nonisolated var diagnosticsCode: String {
    switch self {
    case .vault(let state):
      switch state {
      case .noStorageAccount: "vault.noStorageAccount"
      case .noVault: "vault.noVault"
      case .awaitingKey: "vault.awaitingKey"
      case .partiallyReadable: "vault.partiallyReadable"
      case .ready: "vault.ready"
      }
    case .deviceLocked: "deviceLocked"
    case .keychainUnavailable: "keychainUnavailable"
    case .accountUnavailable: "accountUnavailable"
    case .accountChanged: "accountChanged"
    case .storageRemoved: "storageRemoved"
    case .appUpdateRequired: "appUpdateRequired"
    case .detached: "detached"
    case .settingsUnreadable: "settingsUnreadable"
    case .vaultMismatch: "vaultMismatch"
    case .vaultUnrecognized: "vaultUnrecognized"
    case .vaultMoved: "vaultMoved"
    case .moveInProgress: "moveInProgress"
    }
  }
}

extension StorageClassPolicy {
  nonisolated var diagnosticsCode: String {
    switch self {
    case .iCloud: "iCloud"
    case .unrestricted: "unrestricted"
    }
  }
}
