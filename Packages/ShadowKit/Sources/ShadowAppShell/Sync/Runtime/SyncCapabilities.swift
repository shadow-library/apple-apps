import Foundation
import ShadowSyncCloudKit

/// The restricted capabilities this build was signed with, read from the `ShadowCapabilities` Info.plist dictionary that `Project.app` writes only for the
/// entitlements it emitted. A build without a team has none, and creating a CloudKit container without its entitlement raises an exception.
public nonisolated struct SyncCapabilities: Equatable, Sendable {
  public static let infoPlistKey = "ShadowCapabilities"

  public let cloudKitContainer: String?
  public let receivesPushes: Bool
  /// The shared keychain access group with its team prefix, which Xcode expands only when it signs with a team.
  public let sharedKeychainGroup: String?

  public init(cloudKitContainer: String? = nil, receivesPushes: Bool = false, sharedKeychainGroup: String? = nil) {
    self.cloudKitContainer = cloudKitContainer
    self.receivesPushes = receivesPushes
    self.sharedKeychainGroup = sharedKeychainGroup
  }

  public init(infoDictionary: [String: Any]?) {
    let signed = infoDictionary?[Self.infoPlistKey] as? [String: Any] ?? [:]
    cloudKitContainer = signed["CloudKitContainer"] as? String
    receivesPushes = signed["PushNotifications"] as? Bool ?? false
    sharedKeychainGroup = (signed["SharedKeychainGroup"] as? String).flatMap(Self.expandedGroup)
  }

  public static var current: SyncCapabilities { SyncCapabilities(infoDictionary: Bundle.main.infoDictionary) }

  /// iCloud needs the push capability too: `CKZoneClient` runs a sync engine that subscribes to the database.
  public var cloudKit: CloudKitConfiguration? {
    guard receivesPushes, let cloudKitContainer else { return nil }
    return try? CloudKitConfiguration(containerIdentifier: cloudKitContainer)
  }

  /// A group whose prefix is not a ten-character team or bundle seed id was not expanded, so the app keeps its keys in its own group.
  public static func expandedGroup(_ group: String) -> String? {
    guard let dot = group.firstIndex(of: ".") else { return nil }
    let prefix = group[..<dot]
    let isSeed = prefix.count == 10 && prefix.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    return isSeed && group.index(after: dot) < group.endIndex ? group : nil
  }
}
