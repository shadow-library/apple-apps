import Foundation
import ShadowCore
import ShadowSync

/// A move this device has started and not finished. While one is saved, no engine may run for the vault: finish it with `SyncMover` or `SyncMoveFollower` first.
public enum SyncMoveJournal: Sendable, Equatable, Codable {
  case movingOut(from: ReplicaID, target: SyncLocation)
  case following(from: ReplicaID, target: SyncLocation)

  public static let currentFormat = 1

  public var from: ReplicaID {
    switch self {
    case .movingOut(let from, _), .following(let from, _): from
    }
  }

  public var target: SyncLocation {
    switch self {
    case .movingOut(_, let target), .following(_, let target): target
    }
  }

  private enum Role: String, Codable {
    case movingOut = "moving-out"
    case following
  }

  private enum CodingKeys: String, CodingKey {
    case format
    case role
    case from
    case target
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(Int.self, forKey: .format) == Self.currentFormat else {
      throw DecodingError.dataCorruptedError(forKey: .format, in: container, debugDescription: "Only format \(Self.currentFormat) is read")
    }
    let from = try container.decode(ReplicaID.self, forKey: .from)
    let target = try container.decode(SyncLocation.self, forKey: .target)
    switch try container.decode(Role.self, forKey: .role) {
    case .movingOut: self = .movingOut(from: from, target: target)
    case .following: self = .following(from: from, target: target)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentFormat, forKey: .format)
    switch self {
    case .movingOut: try container.encode(Role.movingOut, forKey: .role)
    case .following: try container.encode(Role.following, forKey: .role)
    }
    try container.encode(from, forKey: .from)
    try container.encode(target, forKey: .target)
  }
}

/// Beside the location file, outside every vault directory. An unreadable journal is an error, never an absent one: forgetting a move half done would let
/// the old engine run under the moved replica.
public struct SyncMoveJournalStore: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url.standardizedFileURL
  }

  public init(beside locations: SyncLocationStore) {
    self.init(url: locations.url.deletingLastPathComponent().appending(path: "move.json", directoryHint: .notDirectory))
  }

  public func load() throws(SyncMoveError) -> SyncMoveJournal? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      guard Self.isMissing(error) else { throw .journal(Self.reason(error)) }
      return nil
    }
    do {
      return try JSONDecoder().decode(SyncMoveJournal.self, from: data)
    } catch {
      throw .journal("the saved move cannot be decoded")
    }
  }

  func save(_ journal: SyncMoveJournal) throws(SyncMoveError) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(journal).write(to: url, options: [.atomic])
    } catch {
      throw .journal(Self.reason(error))
    }
  }

  static func isSaved(_ target: SyncLocation, in locations: SyncLocationStore) throws(SyncMoveError) -> Bool {
    do {
      return try locations.load() == .attached(target)
    } catch {
      throw .location(error)
    }
  }

  func clear() throws(SyncMoveError) {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      guard Self.isMissing(error) else { throw .journal(Self.reason(error)) }
    }
  }

  private static func isMissing(_ error: any Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code)
  }

  private static func reason(_ error: any Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
  }
}
