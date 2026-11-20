import Foundation

/// Answers whether the device has been unlocked since it started, which is when files and keychain items protected until first user
/// authentication become readable. `UIApplication.isProtectedDataAvailable` is the wrong question: it turns false whenever a device with a
/// passcode locks, while sync must keep running in the background.
public struct FirstUnlockProbe: Sendable {
  public let url: URL

  /// Keep the file outside every vault directory.
  public init(url: URL) {
    self.url = url
  }

  public static func defaultURL(applicationSupport: URL, bundleIdentifier: String) -> URL {
    applicationSupport.appending(path: bundleIdentifier, directoryHint: .isDirectory).appending(path: "Sync", directoryHint: .isDirectory)
      .appending(path: "first-unlock", directoryHint: .notDirectory)
  }

  /// Rewriting the file replaces one that cannot be read for any other reason; before the first unlock creating a protected file fails too.
  public func hasUnlockedSinceBoot() -> Bool {
    if (try? Data(contentsOf: url)) != nil { return true }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([1]).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      return true
    } catch {
      return false
    }
  }
}
