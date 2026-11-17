import Foundation
import Synchronization

@testable import ShadowStore

final class RecordingVaultFiles: VaultFiles {
  private struct State {
    var protections: [String: FileProtectionType] = [:]
    var applied: [String] = []
    var excluded: [String: Bool] = [:]
  }

  let enforcesProtection: Bool
  private let failing: Set<String>
  private let failingExclusion: Set<String>
  private let readBack: FileProtectionType?
  private let state = Mutex(State())

  init(enforcesProtection: Bool = true, failing: Set<String> = [], failingExclusion: Set<String> = [], readBack: FileProtectionType? = nil) {
    self.enforcesProtection = enforcesProtection
    self.failing = failing
    self.failingExclusion = failingExclusion
    self.readBack = readBack
  }

  var applied: [String] { state.withLock { $0.applied } }

  func protectionByName() -> [String: FileProtectionType] {
    state.withLock { $0.protections }
  }

  func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  func protection(of url: URL) throws -> FileProtectionType? {
    readBack ?? state.withLock { $0.protections[url.lastPathComponent] }
  }

  func setProtection(_ protection: FileProtectionType, of url: URL) throws {
    guard !failing.contains(url.lastPathComponent) else { throw CocoaError(.fileWriteNoPermission) }
    state.withLock {
      $0.protections[url.lastPathComponent] = protection
      $0.applied.append(url.lastPathComponent)
    }
  }

  func isExcludedFromBackup(_ url: URL) throws -> Bool {
    state.withLock { $0.excluded[url.lastPathComponent] ?? false }
  }

  func setExcludedFromBackup(_ excluded: Bool, _ url: URL) throws {
    guard !failingExclusion.contains(url.lastPathComponent) else { throw CocoaError(.fileWriteNoPermission) }
    state.withLock { $0.excluded[url.lastPathComponent] = excluded }
  }
}
