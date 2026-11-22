import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

@MainActor
@Suite("MemoirVaultModel", TestTimeLimit.standard)
struct MemoirVaultModelTests {
  private static func model(
    unlocked: Unlock? = nil, _ open: @escaping @Sendable () async throws(MemoirVaultOpenError) -> MemoirOpenedVault
  ) -> MemoirVaultModel {
    MemoirVaultModel(
      open: { _ throws(VaultOpenError) in
        do throws(MemoirVaultOpenError) {
          return try await open()
        } catch {
          throw error.vaultOpenError
        }
      }, hasUnlockedSinceBoot: { unlocked?.isUnlocked ?? true })
  }

  @Test("should start opening and become ready with the opened stores")
  func becomesReady() async throws {
    let model = Self.model { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in try await MemoirVaultOpener.open(.inMemory, appVersion: "1") }
    guard case .opening = model.state else {
      Issue.record("expected the model to start opening")
      return
    }

    await model.open()

    #expect(model.opened != nil)
    #expect(model.failure == nil)
  }

  @Test("should surface a failed open as its typed error and recover on retry")
  func surfacesFailureThenRecovers() async throws {
    let attempts = Attempts()
    let model = Self.model { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in
      guard attempts.next() > 1 else { throw .locationUnavailable("no application support directory") }
      return try await MemoirVaultOpener.open(.inMemory, appVersion: "1")
    }

    await model.open()

    #expect(model.opened == nil)
    #expect(model.failure == .locationUnavailable("no application support directory"))

    await model.open()

    #expect(model.opened != nil)
    #expect(model.failure == nil)
    #expect(attempts.count == 2)
  }

  @Test("should surface a blocked vault directory as an open failure")
  func surfacesOpenFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MemoirTests-\(UUID().uuidString)")
    try Data().write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = try MemoirVault(directory: directory)
    let model = Self.model { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in try await MemoirVaultOpener.open(.vault(vault), appVersion: "1") }

    await model.open()

    guard case .failed(.openFailed) = model.state else {
      Issue.record("expected an open failure, got \(model.state)")
      return
    }
  }

  @Test("should open once when asked twice at the same time, and keep an open vault")
  func opensOnce() async throws {
    let attempts = Attempts()
    let model = Self.model { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in
      _ = attempts.next()
      return try await MemoirVaultOpener.open(.inMemory, appVersion: "1")
    }

    async let first: Void = model.open()
    async let second: Void = model.open()
    _ = await (first, second)
    let replica = try #require(model.opened).stores.main.replica
    await model.open()

    #expect(attempts.count == 1)
    #expect(model.opened?.stores.main.replica == replica)
  }

  @Test("should wait as locked before the first unlock and open once protected data is available")
  func waitsForTheFirstUnlock() async throws {
    let unlocked = Unlock()
    let attempts = Attempts()
    let model = Self.model(unlocked: unlocked) { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in
      guard attempts.next() > 1 else { throw .openFailed("the database file is protected") }
      return try await MemoirVaultOpener.open(.inMemory, appVersion: "1")
    }

    await model.open()

    #expect(model.isLocked)
    #expect(model.failure == nil)

    unlocked.unlock()
    await model.protectedDataBecameAvailable()

    #expect(model.opened != nil)
    #expect(attempts.count == 2)
  }

  @Test("should present each opener failure as the shell's open error")
  func mapsOpenerFailures() {
    #expect(MemoirVaultOpenError.locationUnavailable("gone").vaultOpenError == .locationUnavailable("gone"))
    #expect(MemoirVaultOpenError.openFailed("broken").vaultOpenError == .openFailed("broken"))
    #expect(MemoirVaultOpenError.buildVersionUnavailable.vaultOpenError == .openFailed("the app bundle has no CFBundleVersion"))
  }
}

nonisolated private final class Attempts: Sendable {
  private let value = Mutex(0)

  var count: Int { value.withLock { $0 } }

  func next() -> Int {
    value.withLock {
      $0 += 1
      return $0
    }
  }
}

nonisolated final class Unlock: Sendable {
  private let value = Mutex(false)

  var isUnlocked: Bool { value.withLock { $0 } }

  func unlock() {
    value.withLock { $0 = true }
  }
}
