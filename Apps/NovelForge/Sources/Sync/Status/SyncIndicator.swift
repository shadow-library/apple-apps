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
  init?(_ status: SyncStatus, deviceNames: [ReplicaID: String] = [:]) {
    switch status {
    case .off:
      return nil
    case .upToDate:
      self.init(.upToDate, String(localized: "Up to date", table: "Sync"), String(localized: "Your library is the same on all your devices.", table: "Sync"))
    case .syncing:
      self.init(.syncing, String(localized: "Syncing", table: "Sync"), String(localized: "Changes are being sent and received.", table: "Sync"))
    case .attentionNeeded(let reason):
      let (headline, detail) = Self.problem(reason, deviceNames: deviceNames)
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
    String(localized: "Sync status: \(headline)", table: "Sync")
  }

  private static func problem(_ reason: SyncAttentionReason, deviceNames: [ReplicaID: String]) -> (String, String) {
    switch reason {
    case .quotaFull:
      (String(localized: "Sync storage is full", table: "Sync"), String(localized: "There is no room left for this device's changes.", table: "Sync"))
    case .accountUnavailable:
      (
        String(localized: "Sync account unavailable", table: "Sync"),
        String(localized: "The account your library syncs with is signed out or cannot be reached.", table: "Sync")
      )
    case .accountChanged:
      (
        String(localized: "Signed in to another account", table: "Sync"),
        String(localized: "Your library syncs with a different account, so nothing is sent to this one.", table: "Sync")
      )
    case .storageRemoved:
      (
        String(localized: "Synced copy removed", table: "Sync"),
        String(localized: "Your library's synced copy is gone from its storage. The library on this device is untouched.", table: "Sync")
      )
    case .zoneLost(.purged):
      (
        String(localized: "iCloud data deleted", table: "Sync"),
        String(localized: "Novel Forge's iCloud data was deleted in Settings. The library on this device is untouched.", table: "Sync")
      )
    case .zoneLost(.encryptedDataReset):
      (
        String(localized: "iCloud encrypted data was reset", table: "Sync"),
        String(localized: "Your library's iCloud copy was removed with it. The library on this device is untouched.", table: "Sync")
      )
    case .zoneLost(.missing):
      (
        String(localized: "iCloud copy removed", table: "Sync"),
        String(localized: "Your library's iCloud copy is gone. The library on this device is untouched.", table: "Sync")
      )
    case .vaultMismatch:
      (
        String(localized: "Another library is there", table: "Sync"),
        String(localized: "The sync storage now holds a different library, so this one stopped syncing there.", table: "Sync")
      )
    case .vaultUnrecognized:
      (
        String(localized: "Unrecognized files in sync storage", table: "Sync"),
        String(localized: "The sync storage holds library files that do not say which library they belong to.", table: "Sync")
      )
    case .awaitingKey:
      (
        String(localized: "Waiting for this library's key", table: "Sync"),
        String(localized: "The key arrives from your other devices. Until then this device cannot read the synced library.", table: "Sync")
      )
    case .writingKeyMissing:
      (
        String(localized: "Waiting for the newest key", table: "Sync"),
        String(localized: "Your library moved to a key that has not reached this device from your other devices yet.", table: "Sync")
      )
    case .keysMissing(let replicas):
      (
        String(localized: "Changes from \(devices(replicas, named: deviceNames)) cannot be read yet", table: "Sync"),
        String(localized: "They were sealed with a key that has not reached this device.", table: "Sync")
      )
    case .wrongClock:
      (
        String(localized: "This device's clock is wrong", table: "Sync"),
        String(localized: "Set the date and time to update automatically.", table: "Sync")
      )
    case .appUpdateRequired:
      (
        String(localized: "Update Novel Forge to keep syncing", table: "Sync"),
        String(localized: "Another of your devices synced with a newer version.", table: "Sync")
      )
    case .deviceLocked:
      (
        String(localized: "Unlock this device to sync", table: "Sync"),
        String(localized: "Sync starts once the device has been unlocked after it restarted.", table: "Sync")
      )
    case .keychainUnavailable:
      (
        String(localized: "Sync needs a signed build", table: "Sync"),
        String(localized: "This build cannot use the keychain that keeps your library's key, so nothing syncs here.", table: "Sync")
      )
    case .settingsUnreadable:
      (
        String(localized: "Sync settings cannot be read", table: "Sync"),
        String(localized: "Turn sync on again to choose where your library syncs.", table: "Sync")
      )
    case .vaultMoved:
      (
        String(localized: "Your library moved to another storage location", table: "Sync"),
        String(localized: "Another of your devices moved it. Follow it there to keep syncing, or stay and stop syncing here.", table: "Sync")
      )
    case .moveInProgress:
      (
        String(localized: "Moving your library did not finish", table: "Sync"),
        String(localized: "A move to another storage location stopped part way on this device. Run it again, or give it up.", table: "Sync")
      )
    case .storageUnreachable:
      (
        String(localized: "Sync storage cannot be reached", table: "Sync"),
        String(localized: "Sync tries again on its own.", table: "Sync")
      )
    case .failed:
      (String(localized: "Sync ran into a problem", table: "Sync"), String(localized: "Sync tries again on its own.", table: "Sync"))
    }
  }

  private static func consequence(_ stops: SyncStoppage) -> String {
    switch stops {
    case .everything:
      String(localized: "Nothing syncs until then. Everything you do here is kept on this device.", table: "Sync")
    case .uploads:
      String(localized: "Your changes are kept on this device, and your other devices will not see them until then.", table: "Sync")
    case .downloads:
      String(localized: "Their changes do not appear here until the key arrives. Everything else keeps syncing.", table: "Sync")
    case .nothing:
      String(localized: "Sync keeps running.", table: "Sync")
    }
  }

  /// Known names in order, then one entry for every replica the directory does not name.
  private static func devices(_ replicas: Set<ReplicaID>, named names: [ReplicaID: String]) -> String {
    var listed = Array(Set(replicas.compactMap { names[$0] })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    switch replicas.count(where: { names[$0] == nil }) {
    case 0: break
    case 1: listed.append(listed.isEmpty ? String(localized: "another device", table: "Sync") : String(localized: "one other device", table: "Sync"))
    default: listed.append(String(localized: "other devices", table: "Sync"))
    }
    return listed.formatted(.list(type: .and))
  }

  private static func code(_ reason: SyncAttentionReason) -> String? {
    guard case .failed(let code) = reason else { return nil }
    return code
  }
}
