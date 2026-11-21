import Foundation
import OSLog
import ShadowCore

public enum SyncLocationRecord: Sendable, Equatable {
  /// Nothing was ever attached here, so an automatic provider may attach on its own.
  case firstUse
  /// Nothing attaches until the user turns sync on.
  case turnedOff(SyncTurnedOffReason)
  case attached(SyncLocation)
}

public enum SyncTurnedOffReason: Sendable, Equatable {
  case disconnected
  /// The file is corrupt or oversized.
  case unreadable
  /// A newer version of the app wrote the file.
  case newerFormat
}

/// A corrupt, oversized or newer file reads as turned off, never as first use: a location existed, and attaching on its own could carry one
/// account's data into another. The turned-off mark sits beside the file; a saved location wins over it, so each write order survives a crash.
public struct SyncLocationStore: Sendable {
  public static let maximumBytes = 1 << 20
  private static let logger = Logger(category: "SyncLocationStore")

  public let url: URL
  private let turnedOffURL: URL

  public init(url: URL, outside vaultDirectories: [URL]) throws(SyncLocationError) {
    let file = url.standardizedFileURL
    for directory in vaultDirectories where file.pathComponents.starts(with: directory.standardizedFileURL.pathComponents) {
      throw .insideVaultDirectory(file.path(percentEncoded: false))
    }
    self.url = file
    turnedOffURL = file.appendingPathExtension("off")
  }

  public static func defaultURL(applicationSupport: URL, bundleIdentifier: String) -> URL {
    applicationSupport.appending(path: bundleIdentifier, directoryHint: .isDirectory).appending(path: "Sync", directoryHint: .isDirectory)
      .appending(path: "location.json", directoryHint: .notDirectory)
  }

  public func load() throws(SyncLocationError) -> SyncLocationRecord {
    guard let data = try read(url) else { return try read(turnedOffURL) == nil ? .firstUse : .turnedOff(.disconnected) }
    guard data.count <= Self.maximumBytes else {
      Self.logger.warning("Treating an oversized sync location file as turned off bytes=\(data.count, privacy: .public)")
      return .turnedOff(.unreadable)
    }
    if let format = try? JSONDecoder().decode(SyncLocationFormat.self, from: data).format, format > SyncLocation.currentFormat {
      Self.logger.warning("Treating a sync location file of a newer format as turned off format=\(format, privacy: .public)")
      return .turnedOff(.newerFormat)
    }
    guard let location = try? JSONDecoder().decode(SyncLocation.self, from: data) else {
      Self.logger.warning("Treating an unreadable sync location file as turned off")
      return .turnedOff(.unreadable)
    }
    return .attached(location)
  }

  public func save(_ location: SyncLocation) throws(SyncLocationError) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(location) else { throw .unwritable("the location could not be encoded") }
    try write(data, to: url)
    try remove(turnedOffURL)
  }

  public func turnOff() throws(SyncLocationError) {
    try write(Data(), to: turnedOffURL)
    try remove(url)
  }

  private func read(_ file: URL) throws(SyncLocationError) -> Data? {
    do {
      return try Data(contentsOf: file)
    } catch {
      switch FileFailure(error) {
      case .missing: return nil
      case .denied(let reason): throw .permissionDenied(reason)
      case .other(let reason): throw .unreadable(reason)
      }
    }
  }

  private func write(_ data: Data, to file: URL) throws(SyncLocationError) {
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file, options: [.atomic])
    } catch {
      switch FileFailure(error) {
      case .denied(let reason): throw .permissionDenied(reason)
      case .missing, .other: throw .unwritable(FileFailure.reason(error))
      }
    }
  }

  private func remove(_ file: URL) throws(SyncLocationError) {
    do {
      try FileManager.default.removeItem(at: file)
    } catch {
      switch FileFailure(error) {
      case .missing: return
      case .denied(let reason): throw .permissionDenied(reason)
      case .other(let reason): throw .unwritable(reason)
      }
    }
  }
}

private struct SyncLocationFormat: Decodable {
  let format: Int
}

private enum FileFailure {
  case missing
  case denied(String)
  case other(String)

  init(_ error: any Error) {
    let nsError = error as NSError
    let posix = Self.posixCode(nsError)
    let cocoa = nsError.domain == NSCocoaErrorDomain ? nsError.code : nil
    if posix == ENOENT || posix == ENOTDIR || cocoa == NSFileReadNoSuchFileError || cocoa == NSFileNoSuchFileError {
      self = .missing
    } else if posix == EPERM || posix == EACCES || cocoa == NSFileReadNoPermissionError || cocoa == NSFileWriteNoPermissionError {
      self = .denied(Self.reason(error))
    } else {
      self = .other(Self.reason(error))
    }
  }

  static func reason(_ error: any Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
  }

  private static func posixCode(_ error: NSError) -> Int32? {
    if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
    guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
    return posixCode(underlying)
  }
}
