import Foundation
import ShadowSync
import ShadowSyncRuntime

struct SyncLocationText {
  let app: AppIdentity

  func place(_ settings: SyncProviderSettings) -> String {
    switch settings {
    case .iCloud: String(localized: "Your iCloud account", table: "SyncSettings", bundle: .module)
    case .localFolder(let folder): folder.path
    case .s3(let s3):
      String(
        localized: "\(s3.keyPrefix.isEmpty ? s3.bucket : "\(s3.bucket)/\(s3.keyPrefix)") at \(s3.endpoint.host() ?? s3.endpoint.absoluteString)", table: "SyncSettings",
        bundle: .module)
    case .oneDrive(let drive): drive.vaultFolder
    case .googleDrive(let drive): drive.vaultFolder
    }
  }

  func offReason(_ reason: SyncTurnedOffReason?) -> String {
    switch reason {
    case nil: String(localized: "Your \(app.vaultNoun) is only on this device. Turn on sync to keep it on your other devices too.", table: "SyncSettings", bundle: .module)
    case .disconnected:
      String(localized: "Sync was turned off on this device. Your \(app.vaultNoun) stays here, and its synced copy stays where it was.", table: "SyncSettings", bundle: .module)
    case .unreadable:
      String(
        localized: "This device's sync settings could not be read, so sync stopped. Turn it on again to choose where your \(app.vaultNoun) syncs.", table: "SyncSettings",
        bundle: .module)
    case .newerFormat:
      String(localized: "A newer version of \(app.displayName) saved this device's sync settings. Update \(app.displayName) to sync.", table: "SyncSettings", bundle: .module)
    }
  }

  func advice(_ phase: SyncPhase?) -> String? {
    switch phase {
    case .vaultMismatch:
      String(
        localized: "This location now holds a different \(app.vaultNoun). Disconnect, then turn sync on again to choose which \(app.vaultNoun) to join.", table: "SyncSettings",
        bundle: .module)
    case .vaultUnrecognized: SyncSettingsErrors(app: app).unrecognizedHeadline
    case .storageRemoved:
      String(
        localized: "The synced copy is gone from this location. Disconnect, then turn sync on again to create it anew; your \(app.vaultNoun) here is untouched.",
        table: "SyncSettings", bundle: .module)
    case .accountChanged:
      String(localized: "Sign in again to the account this \(app.vaultNoun) synced with, or disconnect and turn sync on with this account.", table: "SyncSettings", bundle: .module)
    case .appUpdateRequired: SyncSettingsErrors(app: app).newerFormatHeadline
    default: nil
    }
  }
}
