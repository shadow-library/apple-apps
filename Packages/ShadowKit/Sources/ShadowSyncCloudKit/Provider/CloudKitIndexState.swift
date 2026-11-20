import Foundation
import ShadowSync

/// The provider's key index of one zone as of a change token, bound to the iCloud account it was read from. Opaque to its store, which only
/// encodes and decodes it.
public struct CloudKitIndexState: Sendable, Codable, Equatable {
  static let currentFormat = "com.shadow.library.shadowsynccloudkit.index.1"

  let format: String
  let container: String
  let zone: String
  var token: CloudKitChangeToken?
  var zoneStatus: CloudKitZoneStatus
  var accountChange: CloudKitAccountChange?
  var userRecordName: String?
  var entries: [CloudKitIndexEntry]

  init(
    configuration: CloudKitConfiguration, token: CloudKitChangeToken? = nil, zoneStatus: CloudKitZoneStatus = .unknown, accountChange: CloudKitAccountChange? = nil,
    userRecordName: String? = nil, entries: [CloudKitIndexEntry] = []
  ) {
    format = Self.currentFormat
    container = configuration.containerIdentifier
    zone = configuration.zoneName
    self.token = token
    self.zoneStatus = zoneStatus
    self.accountChange = accountChange
    self.userRecordName = userRecordName
    self.entries = entries
  }

  func belongs(to configuration: CloudKitConfiguration) -> Bool {
    container == configuration.containerIdentifier && zone == configuration.zoneName
  }

  var isCurrentFormat: Bool { format == Self.currentFormat }
}

enum CloudKitZoneStatus: Sendable, Codable, Equatable {
  /// Never seen: a missing zone means no vault exists yet, and the first put creates it.
  case unknown
  case present
  /// Seen and then lost: the provider refuses to create the zone again until told to.
  case lost(CloudKitZoneLoss)
}

struct CloudKitIndexEntry: Sendable, Codable, Equatable {
  let key: ObjectKey
  let size: Int
  let modified: Date
}

/// Why the provider refuses every call until the runtime attaches again.
public enum CloudKitStorageCondition: Sendable, Equatable {
  case zoneLost(CloudKitZoneLoss)
  case accountChanged(CloudKitAccountChange)

  var error: StorageError {
    switch self {
    case .zoneLost(let loss): .unavailable(loss.explanation)
    case .accountChanged(.signedOut): .unauthenticated
    case .accountChanged: .unavailable("The iCloud account changed; the vault must be attached again.")
    }
  }
}

public enum CloudKitStoredIndex: Sendable, Equatable {
  case absent
  case state(CloudKitIndexState)
  /// A saved index exists but cannot be read: the provider reads the zone again but treats it as already seen, so a missing zone counts as lost.
  case unreadable
}

public protocol CloudKitStateStore: Sendable {
  func load() async throws(StorageError) -> CloudKitStoredIndex
  func save(_ state: CloudKitIndexState) async throws(StorageError)
}

public actor InMemoryCloudKitStateStore: CloudKitStateStore {
  public private(set) var state: CloudKitIndexState?
  public private(set) var saveCount = 0
  private var unreadable: Bool

  public init(state: CloudKitIndexState? = nil, unreadable: Bool = false) {
    self.state = state
    self.unreadable = unreadable
  }

  public func load() -> CloudKitStoredIndex {
    if unreadable { return .unreadable }
    return state.map(CloudKitStoredIndex.state) ?? .absent
  }

  public func save(_ state: CloudKitIndexState) {
    saveCount += 1
    unreadable = false
    self.state = state
  }
}

/// Keeps the index as one JSON file, replaced atomically and excluded from backups. It must live outside the vault directory, which may hold only
/// database files. A file that does not decode loads as `.unreadable`.
public struct CloudKitFileStateStore: CloudKitStateStore {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() async throws(StorageError) -> CloudKitStoredIndex {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return .absent
    } catch {
      throw .unavailable("The iCloud index cannot be read: \(error.localizedDescription)")
    }
    guard let state = try? JSONDecoder().decode(CloudKitIndexState.self, from: data) else { return .unreadable }
    return .state(state)
  }

  public func save(_ state: CloudKitIndexState) async throws(StorageError) {
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(state).write(to: fileURL, options: [.atomic])
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var url = fileURL
      try url.setResourceValues(values)
    } catch {
      throw .unavailable("The iCloud index cannot be saved: \(error.localizedDescription)")
    }
  }
}
