import Foundation
import ShadowSync
import ShadowSyncRuntime

enum SyncLocationText {
  static func place(_ settings: SyncProviderSettings) -> String {
    switch settings {
    case .iCloud: String(localized: "Your iCloud account", table: "SyncSettings")
    case .localFolder(let folder): folder.path
    case .s3(let s3):
      String(localized: "\(s3.keyPrefix.isEmpty ? s3.bucket : "\(s3.bucket)/\(s3.keyPrefix)") at \(s3.endpoint.host() ?? s3.endpoint.absoluteString)", table: "SyncSettings")
    case .oneDrive(let drive): drive.vaultFolder
    case .googleDrive(let drive): drive.vaultFolder
    }
  }

  static func offReason(_ reason: SyncTurnedOffReason?) -> String {
    switch reason {
    case nil: String(localized: "Your library is only on this device. Turn on sync to keep it on your other devices too.", table: "SyncSettings")
    case .disconnected: String(localized: "Sync was turned off on this device. Your library stays here, and its synced copy stays where it was.", table: "SyncSettings")
    case .unreadable:
      String(localized: "This device's sync settings could not be read, so sync stopped. Turn it on again to choose where your library syncs.", table: "SyncSettings")
    case .newerFormat: String(localized: "A newer version of Novel Forge saved this device's sync settings. Update Novel Forge to sync.", table: "SyncSettings")
    }
  }

  static func advice(_ phase: SyncPhase?) -> String? {
    switch phase {
    case .vaultMismatch:
      String(localized: "This location now holds a different library. Disconnect, then turn sync on again to choose which library to join.", table: "SyncSettings")
    case .vaultUnrecognized: SyncSettingsErrors.unrecognizedHeadline
    case .storageRemoved:
      String(localized: "The synced copy is gone from this location. Disconnect, then turn sync on again to create it anew; your library here is untouched.", table: "SyncSettings")
    case .accountChanged:
      String(localized: "Sign in again to the account this library synced with, or disconnect and turn sync on with this account.", table: "SyncSettings")
    case .appUpdateRequired: SyncSettingsErrors.newerFormatHeadline
    default: nil
    }
  }
}
