import Foundation

/// One record zone of a CloudKit private database, narrowed to what `CloudKitStorageProvider` needs. Every call returns its own outcome;
/// per-record outcomes are keyed by record name and a whole-call failure is thrown.
public protocol CloudKitZoneClient: Sendable {
  var configuration: CloudKitConfiguration { get }

  /// Creates the zone, or does nothing when it exists.
  func ensureZone() async throws(CloudKitZoneError)

  /// Changes after `token` (nil: every record in the zone). Throws `changeTokenExpired` when the server no longer accepts `token`.
  func fetchChanges(since token: CloudKitChangeToken?) async throws(CloudKitZoneError) -> CloudKitChangeBatch

  /// A name the zone does not hold maps to `recordMissing`.
  func fetch(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitObjectRecord, CloudKitZoneError>]

  /// `.ifAbsent` fails a record whose name exists with `recordChanged`; `.overwrite` replaces it.
  func save(_ records: [CloudKitObjectRecord], mode: CloudKitSaveMode) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitRecordSummary, CloudKitZoneError>]

  /// A name the zone does not hold succeeds.
  func delete(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<Void, CloudKitZoneError>]

  func accountStatus() async throws(CloudKitZoneError) -> CloudKitAccountStatus

  /// The signed-in account's user record name, which tells one iCloud account from another.
  func currentUserRecordName() async throws(CloudKitZoneError) -> String

  /// Each call returns an independent stream.
  func events() -> AsyncStream<CloudKitZoneEvent>
}

public struct CloudKitRecordName: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
  }
}

public enum CloudKitPayload: Sendable, Equatable {
  case inline(Data)
  case parts([Data])
}

public struct CloudKitObjectRecord: Sendable, Equatable {
  public let name: CloudKitRecordName
  public let path: String
  public let size: Int
  public let payload: CloudKitPayload

  public init(name: CloudKitRecordName, path: String, size: Int, payload: CloudKitPayload) {
    self.name = name
    self.path = path
    self.size = size
    self.payload = payload
  }
}

/// A record as the change feed and a save report it: its fields without the bytes, and the server's modification date.
public struct CloudKitRecordSummary: Sendable, Equatable {
  public let name: CloudKitRecordName
  public let path: String
  public let size: Int
  public let modified: Date

  public init(name: CloudKitRecordName, path: String, size: Int, modified: Date) {
    self.name = name
    self.path = path
    self.size = size
    self.modified = modified
  }
}

/// Opaque to everything but the client that issued it.
public struct CloudKitChangeToken: Sendable, Hashable, Codable {
  public let data: Data

  public init(data: Data) {
    self.data = data
  }
}

public struct CloudKitChangeBatch: Sendable, Equatable {
  public let changed: [CloudKitRecordSummary]
  public let deleted: [CloudKitRecordName]
  public let token: CloudKitChangeToken
  public let moreComing: Bool

  public init(changed: [CloudKitRecordSummary], deleted: [CloudKitRecordName], token: CloudKitChangeToken, moreComing: Bool) {
    self.changed = changed
    self.deleted = deleted
    self.token = token
    self.moreComing = moreComing
  }
}

public enum CloudKitSaveMode: Sendable, Equatable {
  case ifAbsent
  case overwrite
}

public enum CloudKitAccountStatus: String, Sendable, Codable, Equatable {
  case available
  case noAccount
  case restricted
  case temporarilyUnavailable
  case couldNotDetermine
}

/// User record names, as CloudKit reports them.
public enum CloudKitAccountChange: Sendable, Codable, Equatable {
  case signedIn(current: String)
  case signedOut(previous: String)
  case switched(previous: String, current: String)
}

public enum CloudKitZoneLoss: String, Sendable, Codable, Equatable {
  /// The zone is gone and nothing says why, as when another device deleted it.
  case missing
  /// The user deleted the app's iCloud data in Settings.
  case purged
  /// The user reset their end-to-end encrypted data.
  case encryptedDataReset
}

public enum CloudKitZoneEvent: Sendable, Equatable {
  /// A push or a scheduled fetch suggests the zone may have changed.
  case remoteChange
  case accountChanged(CloudKitAccountChange)
  case zoneDeleted(CloudKitZoneLoss)
}
