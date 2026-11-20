import Foundation
import ShadowSync

public struct OneDriveIndexEntry: Sendable, Codable, Equatable {
  public let itemID: String
  public let name: String
  public let key: ObjectKey
  public let size: Int
  public let eTag: String?
  public let cTag: String?

  public init(itemID: String, name: String, key: ObjectKey, size: Int, eTag: String?, cTag: String?) {
    self.itemID = itemID
    self.name = name
    self.key = key
    self.size = size
    self.eTag = eTag
    self.cTag = cTag
  }
}

/// Where the provider stands in the vault folder's delta feed.
public enum OneDriveFeedPosition: Sendable, Codable, Equatable {
  /// Mid-enumeration: the next page to read.
  case paging(URL)
  /// Caught up: the link that returns later changes.
  case caughtUp(URL)
}

/// The key index and the delta position it reflects. Both change together, so a reload resumes the feed exactly where the index stands.
public struct OneDriveIndexState: Sendable, Codable, Equatable {
  public static let formatVersion = 1

  public let formatVersion: Int
  public let vaultFolder: String
  public var folderID: String?
  /// The app folder that held the vault folder when it was found; a different parent means the folder was moved away.
  public var appFolderID: String?
  public var position: OneDriveFeedPosition?
  /// By item id.
  public var entries: [String: OneDriveIndexEntry]
  /// The index a full enumeration is building; it replaces `entries` once the enumeration reaches its delta link.
  public var replacement: [String: OneDriveIndexEntry]?

  public init(
    vaultFolder: VaultFolderName, folderID: String? = nil, appFolderID: String? = nil, position: OneDriveFeedPosition? = nil,
    entries: [String: OneDriveIndexEntry] = [:], replacement: [String: OneDriveIndexEntry]? = nil
  ) {
    formatVersion = Self.formatVersion
    self.vaultFolder = vaultFolder.rawValue
    self.folderID = folderID
    self.appFolderID = appFolderID
    self.position = position
    self.entries = entries
    self.replacement = replacement
  }
}

public protocol OneDriveStateStore: Sendable {
  func load() async throws(StorageError) -> OneDriveIndexState?
  func save(_ state: OneDriveIndexState) async throws(StorageError)
}

public actor InMemoryOneDriveStateStore: OneDriveStateStore {
  public private(set) var state: OneDriveIndexState?
  public private(set) var saveCount = 0

  public init(state: OneDriveIndexState? = nil) {
    self.state = state
  }

  public func load() -> OneDriveIndexState? {
    state
  }

  public func save(_ state: OneDriveIndexState) {
    saveCount += 1
    self.state = state
  }
}

/// Keeps the state as one JSON file, replaced atomically. A file that cannot be read back loads as nil, which costs a full enumeration and nothing else.
public struct FileOneDriveStateStore: OneDriveStateStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() async throws(StorageError) -> OneDriveIndexState? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return nil
    } catch {
      throw .unavailable("the OneDrive index cannot be read: \(error.localizedDescription)")
    }
    return try? JSONDecoder().decode(OneDriveIndexState.self, from: data)
  }

  public func save(_ state: OneDriveIndexState) async throws(StorageError) {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(state).write(to: url, options: [.atomic])
    } catch {
      throw .unavailable("the OneDrive index cannot be saved: \(error.localizedDescription)")
    }
  }
}
