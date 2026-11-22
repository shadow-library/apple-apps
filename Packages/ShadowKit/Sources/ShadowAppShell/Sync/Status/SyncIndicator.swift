import Foundation
import ShadowCore
import ShadowSyncCloudKit
import ShadowSyncRuntime

/// What the sync indicator shows for a status: nothing while sync is off, otherwise one of three states with a headline, what is wrong and what it stops.
nonisolated struct SyncIndicator: Equatable, Sendable {
  enum Tone: Equatable, Sendable {
    case upToDate
    case syncing
    case attention
  }

  let tone: Tone
  let headline: String
  let detail: String
  /// What the problem keeps from happening; nil unless attention is needed.
  let consequence: String?
  /// The error code of an unexpected failure, shown for support.
  let code: String?

  /// `deviceNames` names the replicas a reason lists, from the vault's replica directory; a replica it lacks is called another device.
  init?(_ status: SyncStatus, deviceNames: [ReplicaID: String] = [:], app: AppIdentity) {
    switch status {
    case .off:
      return nil
    case .upToDate:
      self.init(
        .upToDate, String(localized: "Up to date", table: "Sync", bundle: .module),
        String(localized: "Your \(app.vaultNoun) is the same on all your devices.", table: "Sync", bundle: .module))
    case .syncing:
      self.init(.syncing, String(localized: "Syncing", table: "Sync", bundle: .module), String(localized: "Changes are being sent and received.", table: "Sync", bundle: .module))
    case .attentionNeeded(let reason):
      let (headline, detail) = Self.problem(reason, deviceNames: deviceNames, app: app)
      self.init(.attention, headline, detail, consequence: Self.consequence(reason.stops), code: Self.code(reason))
    }
  }

  private init(_ tone: Tone, _ headline: String, _ detail: String, consequence: String? = nil, code: String? = nil) {
    self.tone = tone
    self.headline = headline
    self.detail = detail
    self.consequence = consequence
    self.code = code
  }

  var accessibilityLabel: String {
    String(localized: "Sync status: \(headline)", table: "Sync", bundle: .module)
  }

  private static func problem(_ reason: SyncAttentionReason, deviceNames: [ReplicaID: String], app: AppIdentity) -> (String, String) {
    switch reason {
    case .quotaFull:
      (
        String(localized: "Sync storage is full", table: "Sync", bundle: .module),
        String(localized: "There is no room left for this device's changes.", table: "Sync", bundle: .module)
      )
    case .accountUnavailable:
      (
        String(localized: "Sync account unavailable", table: "Sync", bundle: .module),
        String(localized: "The account your \(app.vaultNoun) syncs with is signed out or cannot be reached.", table: "Sync", bundle: .module)
      )
    case .accountChanged:
      (
        String(localized: "Signed in to another account", table: "Sync", bundle: .module),
        String(localized: "Your \(app.vaultNoun) syncs with a different account, so nothing is sent to this one.", table: "Sync", bundle: .module)
      )
    case .storageRemoved:
      (
        String(localized: "Synced copy removed", table: "Sync", bundle: .module),
        String(localized: "Your \(app.vaultNoun)'s synced copy is gone from its storage. The \(app.vaultNoun) on this device is untouched.", table: "Sync", bundle: .module)
      )
    case .zoneLost(.purged):
      (
        String(localized: "iCloud data deleted", table: "Sync", bundle: .module),
        String(localized: "\(app.displayName)'s iCloud data was deleted in Settings. The \(app.vaultNoun) on this device is untouched.", table: "Sync", bundle: .module)
      )
    case .zoneLost(.encryptedDataReset):
      (
        String(localized: "iCloud encrypted data was reset", table: "Sync", bundle: .module),
        String(localized: "Your \(app.vaultNoun)'s iCloud copy was removed with it. The \(app.vaultNoun) on this device is untouched.", table: "Sync", bundle: .module)
      )
    case .zoneLost(.missing):
      (
        String(localized: "iCloud copy removed", table: "Sync", bundle: .module),
        String(localized: "Your \(app.vaultNoun)'s iCloud copy is gone. The \(app.vaultNoun) on this device is untouched.", table: "Sync", bundle: .module)
      )
    case .vaultMismatch:
      (
        String(localized: "Another \(app.vaultNoun) is there", table: "Sync", bundle: .module),
        String(localized: "The sync storage now holds a different \(app.vaultNoun), so this one stopped syncing there.", table: "Sync", bundle: .module)
      )
    case .vaultUnrecognized:
      (
        String(localized: "Unrecognized files in sync storage", table: "Sync", bundle: .module),
        String(localized: "The sync storage holds \(app.vaultNoun) files that do not say which \(app.vaultNoun) they belong to.", table: "Sync", bundle: .module)
      )
    case .awaitingKey:
      (
        String(localized: "Waiting for this \(app.vaultNoun)'s key", table: "Sync", bundle: .module),
        String(localized: "The key arrives from your other devices. Until then this device cannot read the synced \(app.vaultNoun).", table: "Sync", bundle: .module)
      )
    case .writingKeyMissing:
      (
        String(localized: "Waiting for the newest key", table: "Sync", bundle: .module),
        String(localized: "Your \(app.vaultNoun) moved to a key that has not reached this device from your other devices yet.", table: "Sync", bundle: .module)
      )
    case .keysMissing(let replicas):
      (
        String(localized: "Changes from \(devices(replicas, named: deviceNames)) cannot be read yet", table: "Sync", bundle: .module),
        String(localized: "They were sealed with a key that has not reached this device.", table: "Sync", bundle: .module)
      )
    case .wrongClock:
      (
        String(localized: "This device's clock is wrong", table: "Sync", bundle: .module),
        String(localized: "Set the date and time to update automatically.", table: "Sync", bundle: .module)
      )
    case .appUpdateRequired:
      (
        String(localized: "Update \(app.displayName) to keep syncing", table: "Sync", bundle: .module),
        String(localized: "Another of your devices synced with a newer version.", table: "Sync", bundle: .module)
      )
    case .deviceLocked:
      (
        String(localized: "Unlock this device to sync", table: "Sync", bundle: .module),
        String(localized: "Sync starts once the device has been unlocked after it restarted.", table: "Sync", bundle: .module)
      )
    case .keychainUnavailable:
      (
        String(localized: "Sync needs a signed build", table: "Sync", bundle: .module),
        String(localized: "This build cannot use the keychain that keeps your \(app.vaultNoun)'s key, so nothing syncs here.", table: "Sync", bundle: .module)
      )
    case .settingsUnreadable:
      (
        String(localized: "Sync settings cannot be read", table: "Sync", bundle: .module),
        String(localized: "Turn sync on again to choose where your \(app.vaultNoun) syncs.", table: "Sync", bundle: .module)
      )
    case .vaultMoved:
      (
        String(localized: "Your \(app.vaultNoun) moved to another storage location", table: "Sync", bundle: .module),
        String(localized: "Another of your devices moved it. Follow it there to keep syncing, or stay and stop syncing here.", table: "Sync", bundle: .module)
      )
    case .moveInProgress:
      (
        String(localized: "Moving your \(app.vaultNoun) did not finish", table: "Sync", bundle: .module),
        String(localized: "A move to another storage location stopped part way on this device. Run it again, or give it up.", table: "Sync", bundle: .module)
      )
    case .storageUnreachable:
      (
        String(localized: "Sync storage cannot be reached", table: "Sync", bundle: .module),
        String(localized: "Sync tries again on its own.", table: "Sync", bundle: .module)
      )
    case .failed:
      (String(localized: "Sync ran into a problem", table: "Sync", bundle: .module), String(localized: "Sync tries again on its own.", table: "Sync", bundle: .module))
    }
  }

  private static func consequence(_ stops: SyncStoppage) -> String {
    switch stops {
    case .everything:
      String(localized: "Nothing syncs until then. Everything you do here is kept on this device.", table: "Sync", bundle: .module)
    case .uploads:
      String(localized: "Your changes are kept on this device, and your other devices will not see them until then.", table: "Sync", bundle: .module)
    case .downloads:
      String(localized: "Their changes do not appear here until the key arrives. Everything else keeps syncing.", table: "Sync", bundle: .module)
    case .nothing:
      String(localized: "Sync keeps running.", table: "Sync", bundle: .module)
    }
  }

  /// Known names in order, then one entry for every replica the directory does not name.
  private static func devices(_ replicas: Set<ReplicaID>, named names: [ReplicaID: String]) -> String {
    var listed = Array(Set(replicas.compactMap { names[$0] })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    switch replicas.count(where: { names[$0] == nil }) {
    case 0: break
    case 1:
      listed.append(listed.isEmpty ? String(localized: "another device", table: "Sync", bundle: .module) : String(localized: "one other device", table: "Sync", bundle: .module))
    default: listed.append(String(localized: "other devices", table: "Sync", bundle: .module))
    }
    return listed.formatted(.list(type: .and))
  }

  private static func code(_ reason: SyncAttentionReason) -> String? {
    guard case .failed(let code) = reason else { return nil }
    return code
  }
}
