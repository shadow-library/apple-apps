import Foundation
import ShadowSyncRuntime

nonisolated struct SyncProviderOption: Equatable, Identifiable, Sendable {
  enum Unavailability: Equatable, Sendable {
    /// The build was signed without the iCloud and push capabilities, so it never touches CloudKit.
    case notSignedForICloud
    case noAppRegistration
  }

  let kind: SyncProviderKind
  let unavailability: Unavailability?

  var id: SyncProviderKind { kind }
  var isAvailable: Bool { unavailability == nil }

  static func all(hasICloud: Bool) -> [SyncProviderOption] {
    SyncProviderKind.allCases.map { kind in
      switch kind {
      case .iCloud: SyncProviderOption(kind: kind, unavailability: hasICloud ? nil : .notSignedForICloud)
      case .localFolder, .s3: SyncProviderOption(kind: kind, unavailability: nil)
      case .oneDrive, .googleDrive: SyncProviderOption(kind: kind, unavailability: .noAppRegistration)
      }
    }
  }

  var name: String { Self.name(of: kind) }

  var summary: String {
    switch kind {
    case .iCloud: String(localized: "Your private iCloud storage, with no sign-in.", table: "SyncSettings", bundle: .module)
    case .localFolder: String(localized: "A folder on this device or a drive, which you can back up or share with another sync tool.", table: "SyncSettings", bundle: .module)
    case .s3: String(localized: "A bucket on Amazon S3 or a compatible service, with your own access key.", table: "SyncSettings", bundle: .module)
    case .oneDrive: String(localized: "The app folder of your OneDrive.", table: "SyncSettings", bundle: .module)
    case .googleDrive: String(localized: "Google Drive's hidden app data folder.", table: "SyncSettings", bundle: .module)
    }
  }

  func reason(app: AppIdentity) -> String? {
    switch unavailability {
    case nil: nil
    case .notSignedForICloud: String(localized: "This build of \(app.displayName) was not signed for iCloud, so it cannot use it.", table: "SyncSettings", bundle: .module)
    case .noAppRegistration where kind == .oneDrive:
      String(localized: "Not available yet: \(app.displayName) is not registered with Microsoft, so it cannot sign in to OneDrive.", table: "SyncSettings", bundle: .module)
    case .noAppRegistration:
      String(localized: "Not available yet: \(app.displayName) is not registered with Google, so it cannot sign in to Google Drive.", table: "SyncSettings", bundle: .module)
    }
  }

  var systemImage: String { Self.systemImage(of: kind) }

  static func name(of kind: SyncProviderKind) -> String {
    switch kind {
    case .iCloud: String(localized: "iCloud", table: "SyncSettings", bundle: .module)
    case .localFolder: String(localized: "Folder", table: "SyncSettings", bundle: .module)
    case .s3: String(localized: "S3-compatible storage", table: "SyncSettings", bundle: .module)
    case .oneDrive: String(localized: "OneDrive", table: "SyncSettings", bundle: .module)
    case .googleDrive: String(localized: "Google Drive", table: "SyncSettings", bundle: .module)
    }
  }

  static func systemImage(of kind: SyncProviderKind) -> String {
    switch kind {
    case .iCloud: "icloud"
    case .localFolder: "folder"
    case .s3: "externaldrive.connected.to.line.below"
    case .oneDrive, .googleDrive: "cloud"
    }
  }
}
