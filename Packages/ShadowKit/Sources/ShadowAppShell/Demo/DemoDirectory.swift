import Foundation

/// Where an app keeps its demo vault: `<Application Support>/<bundle id>/Demo/`, beside `Vaults/` and never inside it, so nothing that reads the owner's
/// vaults or sync files finds it; a fresh temporary directory while XCTest hosts the app.
public nonisolated enum DemoDirectory {
  public static let name = "Demo"
  /// Shows the demo when the app is launched with it, as App Review notes and UI tests do.
  public static let launchArgument = "-ShadowDemo"

  public static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
    arguments.contains(launchArgument)
  }

  public static func `default`(fileManager: FileManager = .default, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws(VaultOpenError) -> URL {
    let vault = try VaultDirectory.default(fileManager: fileManager, bundleIdentifier: bundleIdentifier)
    return vault.deletingLastPathComponent().deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
  }

  public static func appLocation() throws(VaultOpenError) -> URL {
    guard !VaultDirectory.isHostedByTests else {
      return FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
    return try `default`()
  }

  /// Removes whatever a demo left at `url`, as one the app was quit in, and makes the directory again, empty and excluded from backups.
  public static func recreate(_ url: URL, fileManager: FileManager = .default) throws(VaultOpenError) {
    try remove(url, fileManager: fileManager)
    do {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var excluded = url
      try excluded.setResourceValues(values)
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
  }

  public static func remove(_ url: URL, fileManager: FileManager = .default) throws(VaultOpenError) {
    guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
    do {
      try fileManager.removeItem(at: url)
    } catch {
      throw .locationUnavailable(error.localizedDescription)
    }
  }
}
