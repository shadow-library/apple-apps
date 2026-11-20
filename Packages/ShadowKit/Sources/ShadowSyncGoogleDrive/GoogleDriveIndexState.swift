import Foundation
import ShadowSync

/// The provider's index of one vault as of a change-feed position. Opaque to its store, which only encodes and decodes it.
public struct GoogleDriveIndexState: Sendable, Codable, Equatable {
  static let currentFormat = "com.shadow.library.shadowsyncgoogledrive.index.1"

  let format: String
  let vault: String
  let pageToken: String
  let files: [GoogleDriveIndexedFile]
  let removed: [String]
  let settleAt: Date?
  let tokenFromRebuild: Bool
  let rebuildBlockedUntil: Date?
  let rebuildBackoff: TimeInterval?

  init(
    vault: String, pageToken: String, files: [GoogleDriveIndexedFile], removed: [String], settleAt: Date?, tokenFromRebuild: Bool, rebuildBlockedUntil: Date? = nil,
    rebuildBackoff: TimeInterval? = nil
  ) {
    format = Self.currentFormat
    self.vault = vault
    self.pageToken = pageToken
    self.files = files
    self.removed = removed
    self.settleAt = settleAt
    self.tokenFromRebuild = tokenFromRebuild
    self.rebuildBlockedUntil = rebuildBlockedUntil
    self.rebuildBackoff = rebuildBackoff
  }
}

struct GoogleDriveIndexedFile: Sendable, Codable, Hashable {
  let id: String
  let key: ObjectKey
  let size: Int
  let version: Int64
  let modifiedTime: Date

  /// Every device applies the same rule to the same server metadata: the latest modification wins, and on a tie the smallest file id.
  func wins(over other: Self) -> Bool {
    if modifiedTime != other.modifiedTime { return modifiedTime > other.modifiedTime }
    return id.utf8.lexicographicallyPrecedes(other.id.utf8)
  }
}

public protocol GoogleDriveStateStore: Sendable {
  func load() async throws(StorageError) -> GoogleDriveIndexState?
  func save(_ state: GoogleDriveIndexState) async throws(StorageError)
}

public actor InMemoryGoogleDriveStateStore: GoogleDriveStateStore {
  public private(set) var state: GoogleDriveIndexState?
  private(set) var saveCount = 0

  public init(state: GoogleDriveIndexState? = nil) {
    self.state = state
  }

  public func load() -> GoogleDriveIndexState? {
    state
  }

  public func save(_ state: GoogleDriveIndexState) {
    self.state = state
    saveCount += 1
  }
}

/// Keeps the index in one JSON file, replaced atomically. A file that does not decode is treated as absent, so the index is rebuilt from Drive.
public struct GoogleDriveFileStateStore: GoogleDriveStateStore {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws(StorageError) -> GoogleDriveIndexState? {
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .underlying("The Google Drive index could not be read.")
    }
    return try? JSONDecoder().decode(GoogleDriveIndexState.self, from: data)
  }

  public func save(_ state: GoogleDriveIndexState) throws(StorageError) {
    do {
      let data = try JSONEncoder().encode(state)
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw .underlying("The Google Drive index could not be saved.")
    }
  }
}
