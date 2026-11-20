import Foundation
import ShadowNetworking
import ShadowSync
import ShadowSyncCloudKit
import ShadowSyncGoogleDrive
import ShadowSyncOneDrive
import ShadowSyncS3

public enum SyncProviderSettings: Sendable, Hashable {
  case iCloud(SyncICloudSettings)
  case localFolder(SyncLocalFolderSettings)
  case s3(SyncS3Settings)
  case oneDrive(SyncOneDriveSettings)
  case googleDrive(SyncGoogleDriveSettings)

  public var kind: SyncProviderKind {
    switch self {
    case .iCloud: .iCloud
    case .localFolder: .localFolder
    case .s3: .s3
    case .oneDrive: .oneDrive
    case .googleDrive: .googleDrive
    }
  }
}

public struct SyncICloudSettings: Sendable, Hashable, Codable {
  public let containerIdentifier: String
  public let zoneName: String

  public init(_ configuration: CloudKitConfiguration) {
    containerIdentifier = configuration.containerIdentifier
    zoneName = configuration.zoneName
  }

  public func configuration() throws(CloudKitConfigurationError) -> CloudKitConfiguration {
    try CloudKitConfiguration(containerIdentifier: containerIdentifier, zoneName: zoneName)
  }
}

public struct SyncLocalFolderSettings: Sendable, Hashable, Codable {
  public let path: String
  public let bookmark: Data?

  public init(url: URL, bookmark: Data? = nil) {
    path = url.standardizedFileURL.path(percentEncoded: false)
    self.bookmark = bookmark
  }

  public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

public struct SyncS3Settings: Sendable, Hashable, Codable {
  public let endpoint: URL
  public let region: String
  public let bucket: String
  public let keyPrefix: String
  public let addressingStyle: String
  public let supportsConditionalWrites: Bool
  public let allowsInsecureLocalhost: Bool

  public init(_ configuration: S3Configuration) {
    endpoint = configuration.endpoint
    region = configuration.region
    bucket = configuration.bucket
    keyPrefix = configuration.keyPrefix
    addressingStyle = configuration.addressingStyle.rawValue
    supportsConditionalWrites = configuration.supportsConditionalWrites
    allowsInsecureLocalhost = configuration.allowsInsecureLocalhost
  }

  public func configuration() throws(S3ConfigurationError) -> S3Configuration {
    guard let style = S3Configuration.AddressingStyle(rawValue: addressingStyle) else { throw .invalidEndpoint("The addressing style \(addressingStyle) is unknown.") }
    return try S3Configuration(
      endpoint: endpoint, region: region, bucket: bucket, keyPrefix: keyPrefix, addressingStyle: style, supportsConditionalWrites: supportsConditionalWrites,
      allowsInsecureLocalhost: allowsInsecureLocalhost)
  }
}

public struct SyncOneDriveSettings: Sendable, Hashable, Codable {
  public let clientID: String
  public let redirectURI: URL
  public let vaultFolder: String
  public let audience: String

  public init(_ configuration: OneDriveConfiguration) {
    clientID = configuration.oauth.clientID
    redirectURI = configuration.oauth.redirectURI
    vaultFolder = configuration.vaultFolder.rawValue
    audience = configuration.audience.rawValue
  }

  public func configuration() throws(OAuthError) -> OneDriveConfiguration {
    guard let folder = VaultFolderName(vaultFolder) else { throw .invalidConfiguration("The vault folder name \(vaultFolder) is not valid.") }
    guard let audience = OneDriveConfiguration.Audience(rawValue: audience) else { throw .invalidConfiguration("The audience \(audience) is unknown.") }
    return try OneDriveConfiguration(clientID: clientID, redirectURI: redirectURI, vaultFolder: folder, audience: audience)
  }
}

public struct SyncGoogleDriveSettings: Sendable, Hashable, Codable {
  public let clientID: String
  public let redirectURI: URL
  public let vaultFolder: String

  public init(_ configuration: GoogleDriveConfiguration) {
    clientID = configuration.oauth.clientID
    redirectURI = configuration.oauth.redirectURI
    vaultFolder = configuration.vaultFolder.rawValue
  }

  public func configuration() throws(OAuthError) -> GoogleDriveConfiguration {
    guard let folder = VaultFolderName(vaultFolder) else { throw .invalidConfiguration("The vault folder name \(vaultFolder) is not valid.") }
    return try GoogleDriveConfiguration(clientID: clientID, redirectURI: redirectURI, vaultFolder: folder)
  }
}
