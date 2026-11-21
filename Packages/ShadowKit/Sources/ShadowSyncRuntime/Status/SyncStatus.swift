import Foundation
import ShadowCore
import ShadowSync
import ShadowSyncCloudKit

public enum SyncStatus: Sendable, Equatable {
  /// Sync is not set up on this device or the user turned it off; no indicator is shown.
  case off
  case upToDate
  case syncing
  case attentionNeeded(SyncAttentionReason)
}

/// What a problem keeps from happening; the app's own work never waits on it.
public enum SyncStoppage: Sendable, Equatable {
  case everything
  case uploads
  case downloads(from: Set<ReplicaID>)
  case nothing
}

public enum SyncAttentionReason: Sendable, Equatable {
  case quotaFull
  /// Signed out, or the account cannot be reached or confirmed.
  case accountUnavailable
  case accountChanged
  case storageRemoved
  /// The vault's iCloud zone is gone; it is never created again without asking.
  case zoneLost(CloudKitZoneLoss)
  case vaultMismatch(expected: VaultID, found: VaultID)
  case vaultUnrecognized
  /// This device holds no key of the vault yet.
  case awaitingKey
  /// The vault moved to a key this device does not hold yet, so its changes stay here.
  case writingKeyMissing
  /// Files of these replicas are sealed with keys that have not reached this device.
  case keysMissing(replicas: Set<ReplicaID>)
  /// The device clock is off from trusted time; uploads stop only while the local store stamps changes with it.
  case wrongClock(skew: Duration, stopsUploads: Bool)
  case appUpdateRequired
  case deviceLocked
  /// The keychain refuses this build, which carries no application identifier, so no vault key can be kept; only a build signed with a team syncs.
  case keychainUnavailable
  /// The saved sync location cannot be read; unlike a disconnect, the user did not turn sync off.
  case settingsUnreadable
  case storageUnreachable
  /// The vault moved to the notice's location; follow it there, or stay and give up what changes there.
  case vaultMoved(VaultMoveNotice)
  /// A move or follow on this device is unfinished, or its journal cannot be read; run it again, or give it up with `SyncRuntime.abandonMove()`.
  case moveInProgress
  case failed(code: String)

  public var stops: SyncStoppage {
    switch self {
    case .quotaFull, .writingKeyMissing: .uploads
    case .wrongClock(_, let stopsUploads): stopsUploads ? .uploads : .nothing
    case .keysMissing(let replicas): .downloads(from: replicas)
    case .accountUnavailable, .accountChanged, .storageRemoved, .zoneLost, .vaultMismatch, .vaultUnrecognized, .awaitingKey, .appUpdateRequired, .deviceLocked,
      .keychainUnavailable, .settingsUnreadable, .storageUnreachable, .vaultMoved, .moveInProgress, .failed:
      .everything
    }
  }

  init?(phase: SyncPhase) {
    switch phase {
    case .vault(.awaitingKey): self = .awaitingKey
    case .vault: return nil
    case .detached: return nil
    case .deviceLocked: self = .deviceLocked
    case .keychainUnavailable: self = .keychainUnavailable
    case .accountUnavailable: self = .accountUnavailable
    case .accountChanged: self = .accountChanged
    case .storageRemoved: self = .storageRemoved
    case .appUpdateRequired: self = .appUpdateRequired
    case .settingsUnreadable: self = .settingsUnreadable
    case .vaultMismatch(let expected, let found): self = .vaultMismatch(expected: expected, found: found)
    case .vaultUnrecognized: self = .vaultUnrecognized
    case .vaultMoved(let notice): self = .vaultMoved(notice)
    case .moveInProgress: self = .moveInProgress
    }
  }
}

extension SyncStoppage {
  var severity: Int {
    switch self {
    case .everything: 0
    case .uploads: 1
    case .downloads: 2
    case .nothing: 3
    }
  }
}
