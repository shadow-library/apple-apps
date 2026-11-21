import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import NovelForge

@MainActor
@Suite("VaultModel")
struct VaultModelTests {
  private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the condition never held")
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "NovelForgeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("should open the store in a new directory and load an empty library")
  func opensAndLoadsEmptyLibrary() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = StoreLocation.file(directory.appending(path: "Vaults").appending(path: "vault.sqlite"))
    let model = VaultModel(locate: { location }, hasUnlockedSinceBoot: { true })

    await model.open()

    let store = try #require(model.store)
    let library = try await store.load(LibraryList.self)
    #expect(library.novels.isEmpty)
    #expect(library.archived.isEmpty)
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Vaults").appending(path: "vault.sqlite").path(percentEncoded: false)))
  }

  @Test("should reopen the same vault with the same replica")
  func reopensSameVault() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let first = try await VaultOpener.open(location)
    let second = try await VaultOpener.open(location)
    #expect(first.replica == second.replica)
  }

  @Test("should report a failure when the vault path is blocked by a file")
  func failsWhenPathBlocked() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appending(path: "blocker")
    try Data().write(to: blocker)
    let model = VaultModel(locate: { .file(blocker.appending(path: "vault.sqlite")) }, hasUnlockedSinceBoot: { true })

    await model.open()

    #expect(model.store == nil)
    guard case .openFailed = try #require(model.failure) else {
      Issue.record("expected an open failure")
      return
    }
  }

  @Test("should report a failure when the location cannot be resolved, then recover on retry")
  func recoversAfterLocationFailure() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let attempts = Attempts()
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let model = VaultModel(
      locate: { () throws(VaultOpenError) -> StoreLocation in
        guard attempts.next() > 1 else { throw .locationUnavailable("no application support directory") }
        return location
      }, hasUnlockedSinceBoot: { true })

    await model.open()
    #expect(model.failure == .locationUnavailable("no application support directory"))

    await model.open()
    #expect(model.store != nil)
  }

  @Test("should wait for the device to be unlocked when the vault cannot be opened before the first unlock, then open it")
  func waitsForTheFirstUnlock() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let unlocked = Flag()
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let model = VaultModel(
      locate: { () throws(VaultOpenError) -> StoreLocation in
        guard unlocked.value else { throw .openFailed("the file is protected until the first unlock") }
        return location
      }, hasUnlockedSinceBoot: { unlocked.value })

    await model.open()
    #expect(model.isLocked)
    #expect(model.failure == nil)

    unlocked.set()
    await model.protectedDataBecameAvailable()
    #expect(model.store != nil)
  }

  @Test("should report a failure after the first unlock and leave it for Try Again when protected data becomes available")
  func failsOnceUnlocked() async throws {
    let model = VaultModel(locate: { () throws(VaultOpenError) -> StoreLocation in throw .openFailed("corrupt") }, hasUnlockedSinceBoot: { true })

    await model.open()
    #expect(model.failure == .openFailed("corrupt"))

    await model.protectedDataBecameAvailable()
    #expect(model.failure == .openFailed("corrupt"))
  }

  @Test("should let a second caller wait for the open in flight and see the store when its own call returns")
  func joinsTheOpenInFlight() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let attempts = Attempts()
    let gate = DispatchSemaphore(value: 0)
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let model = VaultModel(
      locate: {
        _ = attempts.next()
        _ = gate.wait(timeout: .now() + 60)
        return location
      }, hasUnlockedSinceBoot: { true })

    let first = Task { await model.open() }
    try await until { attempts.value == 1 }
    let second = Task { () -> Bool in
      await model.open()
      return model.store != nil
    }
    try await Task.sleep(for: .milliseconds(100))
    gate.signal()

    #expect(await second.value)
    await first.value
    #expect(attempts.value == 1)
  }

  @Test("should open a vault whose attempt was still deciding it was locked when the unlock arrived")
  func opensWhenTheUnlockArrivesMidAttempt() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let unlocked = Flag()
    let probe = HeldProbe()
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let model = VaultModel(
      locate: { () throws(VaultOpenError) -> StoreLocation in
        guard unlocked.value else { throw .openFailed("the file is protected until the first unlock") }
        return location
      }, hasUnlockedSinceBoot: { await probe.answer() })

    let opening = Task { await model.open() }
    try await until { probe.isHeld }
    unlocked.set()
    let unlocking = Task { await model.protectedDataBecameAvailable() }
    try await Task.sleep(for: .milliseconds(100))
    probe.release(false)
    await opening.value
    await unlocking.value

    #expect(model.store != nil)
  }

  @Test("should stamp the vault's changes with the trusted clock it was given")
  func stampsWithTheTrustedClock() async throws {
    let clock = TrustedClock()
    let trusted = Date(timeIntervalSince1970: 2_000_000_000)
    clock.record(serverDate: trusted)
    let model = VaultModel(locate: { .inMemory }, trustedClock: clock, hasUnlockedSinceBoot: { true })

    await model.open()
    let store = try #require(model.store)
    _ = try await LibraryService(store: store).create(title: "Ashfall", notes: "")

    let stamped = try #require(try await store.pendingClocks().last).date
    #expect(abs(stamped.timeIntervalSince(trusted)) < 60)
  }

  @Test("should name the vault under the bundle identifier inside Application Support")
  func resolvesDefaultLocation() throws {
    let location = try VaultOpener.defaultLocation(bundleIdentifier: "example.test")
    guard case .file(let url) = location else {
      Issue.record("expected a file location")
      return
    }
    #expect(url.pathComponents.suffix(4) == ["example.test", "Vaults", "Default", "vault.sqlite"])
  }

  @Test("should refuse a missing bundle identifier")
  func refusesMissingBundleIdentifier() {
    #expect(throws: VaultOpenError.self) { try VaultOpener.defaultLocation(bundleIdentifier: nil) }
  }
}

private nonisolated final class Flag: Sendable {
  private let raised = Mutex(false)

  var value: Bool { raised.withLock(\.self) }

  func set() { raised.withLock { $0 = true } }
}

/// Holds the first unlock question until released with an answer; later questions are answered at once with true.
private nonisolated final class HeldProbe: Sendable {
  private let state = Mutex<(held: CheckedContinuation<Bool, Never>?, asked: Int)>((nil, 0))

  var isHeld: Bool { state.withLock { $0.held != nil } }

  func answer() async -> Bool {
    await withCheckedContinuation { continuation in
      let first = state.withLock { state in
        state.asked += 1
        guard state.asked == 1 else { return false }
        state.held = continuation
        return true
      }
      if !first { continuation.resume(returning: true) }
    }
  }

  func release(_ answer: Bool) {
    state.withLock { state in
      defer { state.held = nil }
      return state.held
    }?.resume(returning: answer)
  }
}

private nonisolated final class Attempts: Sendable {
  private let count = Mutex(0)

  var value: Int { count.withLock(\.self) }

  func next() -> Int {
    count.withLock { value in
      value += 1
      return value
    }
  }
}
