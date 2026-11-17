import Foundation

protocol VaultFiles: Sendable {
  var enforcesProtection: Bool { get }
  func exists(_ url: URL) -> Bool
  func protection(of url: URL) throws -> FileProtectionType?
  func setProtection(_ protection: FileProtectionType, of url: URL) throws
  func isExcludedFromBackup(_ url: URL) throws -> Bool
  func setExcludedFromBackup(_ excluded: Bool, _ url: URL) throws
}

struct SystemVaultFiles: VaultFiles {
  var enforcesProtection: Bool {
    #if os(macOS)
      false
    #else
      true
    #endif
  }

  func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  func protection(of url: URL) throws -> FileProtectionType? {
    try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.protectionKey] as? FileProtectionType
  }

  func setProtection(_ protection: FileProtectionType, of url: URL) throws {
    try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path(percentEncoded: false))
  }

  func isExcludedFromBackup(_ url: URL) throws -> Bool {
    try URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
  }

  func setExcludedFromBackup(_ excluded: Bool, _ url: URL) throws {
    var url = URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
    var values = URLResourceValues()
    values.isExcludedFromBackup = excluded
    try url.setResourceValues(values)
  }
}

struct VaultFileProtection {
  static let required = FileProtectionType.completeUntilFirstUserAuthentication
  static let sidecarSuffixes = ["", "-wal", "-shm"]

  let files: any VaultFiles

  func prepare(directory: URL) throws(StoreError) {
    guard files.enforcesProtection else { return }
    try apply(to: directory)
  }

  func seal(database: URL) throws(StoreError) {
    guard files.enforcesProtection else { return }
    for suffix in Self.sidecarSuffixes {
      let url = URL(filePath: database.path(percentEncoded: false) + suffix)
      if files.exists(url) { try apply(to: url) }
    }
  }

  private func apply(to url: URL) throws(StoreError) {
    let path = url.lastPathComponent
    do {
      try files.setProtection(Self.required, of: url)
      guard let actual = try files.protection(of: url), actual != Self.required else { return }
      throw StoreError.fileProtection(path: path, reason: "the file is in protection class \(actual.rawValue)")
    } catch let error as StoreError {
      throw error
    } catch {
      throw .fileProtection(path: path, reason: error.localizedDescription)
    }
  }
}
