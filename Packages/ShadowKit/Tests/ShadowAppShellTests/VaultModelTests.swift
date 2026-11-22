import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import ShadowAppShell

@MainActor
@Suite("VaultModel", TestTimeLimit.standard)
struct VaultModelTests {
  private typealias Locate = @Sendable () throws(VaultOpenError) -> StoreLocation

  private func vault(
    locate: @escaping Locate, trustedClock: TrustedClock = TrustedClock(), hasUnlockedSinceBoot: @escaping VaultModel<VaultStore>.UnlockProbe
  ) -> VaultModel<VaultStore> {
    VaultModel(
      open: { wallClock throws(VaultOpenError) in
        let location = try locate()
        do {
          return try ShellStore.open(location, wallClock: wallClock)
        } catch {
          throw .openFailed(error.localizedDescription)
        }
      }, trustedClock: trustedClock, hasUnlockedSinceBoot: hasUnlockedSinceBoot)
  }

  private func until(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the condition never held")
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ShadowAppShellTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("should open what the app opens in a new directory")
  func opensInANewDirectory() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = StoreLocation.file(directory.appending(path: "Vaults").appending(path: "vault.sqlite"))
    let model = vault(locate: { location }, hasUnlockedSinceBoot: { true })

    await model.open()

    #expect(model.opened != nil)
    #expect(model.failure == nil && !model.isLocked)
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Vaults").appending(path: "vault.sqlite").path(percentEncoded: false)))
  }

  @Test("should report a failure when the vault path is blocked by a file")
  func failsWhenPathBlocked() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocker = directory.appending(path: "blocker")
    try Data().write(to: blocker)
    let model = vault(locate: { .file(blocker.appending(path: "vault.sqlite")) }, hasUnlockedSinceBoot: { true })

    await model.open()

    #expect(model.opened == nil)
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
    let model = vault(
      locate: { () throws(VaultOpenError) -> StoreLocation in
        guard attempts.next() > 1 else { throw .locationUnavailable("no application support directory") }
        return location
      }, hasUnlockedSinceBoot: { true })

    await model.open()
    #expect(model.failure == .locationUnavailable("no application support directory"))

    await model.open()
    #expect(model.opened != nil)
  }

  @Test("should wait for the device to be unlocked when the vault cannot be opened before the first unlock, then open it")
  func waitsForTheFirstUnlock() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let unlocked = Flag()
    let location = StoreLocation.file(directory.appending(path: "vault.sqlite"))
    let model = vault(
      locate: { () throws(VaultOpenError) -> StoreLocation in
        guard unlocked.value else { throw .openFailed("the file is protected until the first unlock") }
        return location
      }, hasUnlockedSinceBoot: { unlocked.value })

    await model.open()
    #expect(model.isLocked)
    #expect(model.failure == nil)

    unlocked.set()
    await model.protectedDataBecameAvailable()
    #expect(model.opened != nil)
  }

  @Test("should report a failure after the first unlock and leave it for Try Again when protected data becomes available")
  func failsOnceUnlocked() async throws {
    let model = vault(locate: { () throws(VaultOpenError) -> StoreLocation in throw .openFailed("corrupt") }, hasUnlockedSinceBoot: { true })

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
    let model = vault(
      locate: {
        _ = attempts.next()
        _ = gate.wait(timeout: .now() + 60)
        return location
      }, hasUnlockedSinceBoot: { true })

    let first = Task { await model.open() }
    try await until { attempts.value == 1 }
    let second = Task { () -> Bool in
      await model.open()
      return model.opened != nil
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
    let model = vault(
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

    #expect(model.opened != nil)
  }

  @Test("should stamp the vault's changes with the trusted clock it was given")
  func stampsWithTheTrustedClock() async throws {
    let clock = TrustedClock()
    let trusted = Date(timeIntervalSince1970: 2_000_000_000)
    clock.record(serverDate: trusted)
    let model = vault(locate: { .inMemory }, trustedClock: clock, hasUnlockedSinceBoot: { true })

    await model.open()
    let store = try #require(model.opened)
    try await ShellStore.writeNote("Ashfall", in: store)

    let stamped = try #require(try await store.pendingClocks().last).date
    #expect(abs(stamped.timeIntervalSince(trusted)) < 60)
  }

  @Test("should close the vault while the body erases it and open a fresh one afterwards")
  func reopensAfterErasing() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "Vaults").appending(path: "vault.sqlite")
    let model = vault(locate: { .file(database) }, hasUnlockedSinceBoot: { true })
    await model.open()
    let before = try #require(model.opened)
    try await ShellStore.writeNote("Ashfall", in: before)

    var closedDuringBody = false
    try await model.reopen { () throws(VaultOpenError) in
      closedDuringBody = model.opened == nil && !model.isLocked && model.failure == nil
      do {
        try FileManager.default.removeItem(at: database.deletingLastPathComponent())
      } catch {
        throw .openFailed(error.localizedDescription)
      }
    }

    let after = try #require(model.opened)
    #expect(closedDuringBody)
    #expect(after !== before)
    #expect(try await after.loadState(.vault).isEmpty)
  }

  @Test("should open the vault again and rethrow when the body fails")
  func reopensAfterAFailedBody() async throws {
    let model = vault(locate: { .inMemory }, hasUnlockedSinceBoot: { true })
    await model.open()
    let before = try #require(model.opened)

    await #expect(throws: VaultOpenError.openFailed("refused")) {
      try await model.reopen { () throws(VaultOpenError) in throw .openFailed("refused") }
    }

    let after = try #require(model.opened)
    #expect(after !== before)
  }

  @Test("should make an open that arrives while the vault is closed wait for it to open again")
  func holdsOpensWhileClosed() async throws {
    let attempts = Attempts()
    let model = vault(
      locate: {
        _ = attempts.next()
        return .inMemory
      }, hasUnlockedSinceBoot: { true })
    await model.open()
    let released = Flag()

    let reopening = Task {
      try await model.reopen { () throws(VaultOpenError) in
        while !released.value { try? await Task.sleep(for: .milliseconds(10)) }
      }
    }
    try await until { model.opened == nil }
    let opening = Task { () -> Bool in
      await model.open()
      return model.opened != nil
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(attempts.value == 1, "no open runs while the body holds the vault closed")
    released.set()

    try await reopening.value
    #expect(await opening.value)
    #expect(attempts.value == 2)
  }

  @Test("should run reopens one at a time and hold an open until the last has opened the vault again")
  func serializesReopens() async throws {
    let attempts = Attempts()
    let model = vault(
      locate: {
        _ = attempts.next()
        return .inMemory
      }, hasUnlockedSinceBoot: { true })
    await model.open()
    let inside = Attempts()
    let overlapped = Flag()
    let released = Flag()
    let body: @MainActor @Sendable () async throws(VaultOpenError) -> Void = { () async throws(VaultOpenError) in
      if inside.next() > 1 { overlapped.set() }
      repeat { try? await Task.sleep(for: .milliseconds(20)) } while !released.value
      inside.leave()
    }

    let first = Task { try await model.reopen(after: body) }
    try await until { inside.value == 1 }
    let second = Task { try await model.reopen(after: body) }
    let third = Task { try await model.reopen(after: body) }
    try await Task.sleep(for: .milliseconds(100))
    let opening = Task { () -> Bool in
      await model.open()
      return model.opened != nil
    }
    try await Task.sleep(for: .milliseconds(100))
    released.set()

    try await first.value
    try await second.value
    try await third.value
    #expect(await opening.value)
    #expect(!overlapped.value, "no reopen's body runs while another's does")
    #expect(attempts.value == 4, "the first open and one per reopen; the open that arrived meanwhile only waited")
  }

  @Test("should name the vault under the bundle identifier inside Application Support")
  func resolvesDefaultLocation() throws {
    let url = try VaultDirectory.default(bundleIdentifier: "example.test")
    #expect(url.pathComponents.suffix(3) == ["example.test", "Vaults", "Default"])
  }

  @Test("should refuse a missing bundle identifier")
  func refusesMissingBundleIdentifier() {
    #expect(throws: VaultOpenError.self) { try VaultDirectory.default(bundleIdentifier: nil) }
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

  func leave() {
    count.withLock { $0 -= 1 }
  }
}
