import Foundation
import ShadowSync

/// Where a vault syncs: never holds a secret; credentials and tokens live in the keychain.
public struct SyncLocation: Sendable, Hashable, Codable {
  public static let currentFormat = 1

  public let settings: SyncProviderSettings
  public let vault: VaultID
  public let account: SyncAccountBinding?

  public init(settings: SyncProviderSettings, vault: VaultID, account: SyncAccountBinding?) {
    self.settings = settings
    self.vault = vault
    self.account = account
  }

  public var kind: SyncProviderKind { settings.kind }

  private enum CodingKeys: String, CodingKey {
    case format
    case kind
    case vault
    case account
    case settings
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(Int.self, forKey: .format) == Self.currentFormat else {
      throw DecodingError.dataCorruptedError(forKey: .format, in: container, debugDescription: "Only format \(Self.currentFormat) is read")
    }
    vault = try container.decode(VaultID.self, forKey: .vault)
    account = try container.decodeIfPresent(SyncAccountBinding.self, forKey: .account)
    switch try container.decode(SyncProviderKind.self, forKey: .kind) {
    case .iCloud: settings = .iCloud(try container.decode(SyncICloudSettings.self, forKey: .settings))
    case .localFolder: settings = .localFolder(try container.decode(SyncLocalFolderSettings.self, forKey: .settings))
    case .s3: settings = .s3(try container.decode(SyncS3Settings.self, forKey: .settings))
    case .oneDrive: settings = .oneDrive(try container.decode(SyncOneDriveSettings.self, forKey: .settings))
    case .googleDrive: settings = .googleDrive(try container.decode(SyncGoogleDriveSettings.self, forKey: .settings))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentFormat, forKey: .format)
    try container.encode(kind, forKey: .kind)
    try container.encode(vault, forKey: .vault)
    try container.encodeIfPresent(account, forKey: .account)
    switch settings {
    case .iCloud(let settings): try container.encode(settings, forKey: .settings)
    case .localFolder(let settings): try container.encode(settings, forKey: .settings)
    case .s3(let settings): try container.encode(settings, forKey: .settings)
    case .oneDrive(let settings): try container.encode(settings, forKey: .settings)
    case .googleDrive(let settings): try container.encode(settings, forKey: .settings)
    }
  }
}
