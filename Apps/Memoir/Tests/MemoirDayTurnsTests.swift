import Foundation
import MemoirCore
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

@MainActor
@Suite("MemoirDayTurns", TestTimeLimit.standard)
struct MemoirDayTurnsTests {
  private static let clockChanged = Notification.Name("MemoirDayTurnsTests.clockChanged")

  @Test("should wait for the account's midnight, and walk to the new day when the clock changes significantly")
  func restartsOnASignificantTimeChange() async throws {
    let clock = TestClock(day: 0, minute: 720)
    let waits = HeldWaits()
    let opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: clock.memoir(deviceZone: TestClock.berlin, waitUntil: waits.wait))
    let context = MemoirScreenContext(opened)
    try await context.writer.issue(try TestQuests.zone("UTC"))
    let center = NotificationCenter()
    let turns = MemoirDayTurns(center: center, clockChanges: [Self.clockChanged])
    defer { turns.stop() }
    let days = Recorded<LocalDate>()
    let observing = Task { for try await today in context.observeToday() { days.append(today.date) } }
    defer { observing.cancel() }
    try await TestClock.until("today's first value") { !days.values.isEmpty }
    #expect(days.values == [TestClock.day(0)])

    turns.follow(opened)

    try await TestClock.until("the first wait") { waits.deadlines.count == 1 }
    #expect(waits.deadlines == [TestClock.date(day: 1, minute: 0)], "UTC's midnight, not Berlin's")

    clock.set(day: 2, minute: 360)
    center.post(name: Self.clockChanged, object: nil)

    try await TestClock.until("the restarted wait") { waits.deadlines.count == 2 }
    #expect(waits.cancelled == 1)
    #expect(waits.deadlines.last == TestClock.date(day: 3, minute: 0))
    #expect(try await opened.stores.openDay() == TestClock.day(2))
    try await TestClock.until("today to follow the turn") { days.values.last == TestClock.day(2) }
  }

  @Test("should keep following the same vault, and stop when the vault closes")
  func followsOnceAndStops() async throws {
    let waits = HeldWaits()
    let opened = try await MemoirVaultOpener.open(
      .inMemory, appVersion: "1", clock: TestClock(day: 0, minute: 720).memoir(deviceZone: TestClock.utc, waitUntil: waits.wait))
    let center = NotificationCenter()
    let turns = MemoirDayTurns(center: center, clockChanges: [Self.clockChanged])

    turns.follow(opened)
    turns.follow(opened)
    try await TestClock.until("the first wait") { waits.deadlines.count == 1 }
    turns.follow(nil)
    try await TestClock.until("the wait to be cancelled") { waits.cancelled == 1 }
    center.post(name: Self.clockChanged, object: nil)
    turns.restart()
    try await Task.sleep(for: .milliseconds(200))

    #expect(waits.deadlines.count == 1, "nothing restarts once the vault is closed")
  }

  @Test("should not report a run that a restart cancels inside its refresh, and leave the last run waiting")
  func cancelsQuietlyInsideARefresh() async throws {
    let waits = HeldWaits()
    let opened = try await MemoirVaultOpener.open(
      .inMemory, appVersion: "1", clock: TestClock(day: 0, minute: 720).memoir(deviceZone: TestClock.utc, waitUntil: waits.wait))
    let stopped = Recorded<String>()
    let turns = MemoirDayTurns(center: NotificationCenter(), clockChanges: [], reportStopped: { stopped.append(String(describing: $0)) })
    defer { turns.stop() }
    turns.follow(opened)
    try await TestClock.until("the first wait") { waits.deadlines.count == 1 }

    let gate = WriteGate()
    let holding = Task { try await opened.stores.main.write { _ in gate.hold() } }
    try await TestClock.until("the write to be held") { gate.isHolding }
    turns.restart()
    try await Task.sleep(for: .milliseconds(100))
    turns.restart()
    try await Task.sleep(for: .milliseconds(100))
    gate.release()
    try await holding.value

    try await TestClock.until("the last run to wait") { waits.deadlines.count == 2 }
    try await Task.sleep(for: .milliseconds(200))
    #expect(stopped.values.isEmpty)
    #expect(waits.deadlines.count == 2, "the run cancelled inside its refresh never waits")
    #expect(waits.cancelled == 1)
  }
}

/// Holds the store's writer inside a write until released, so a refresh queued behind it is still in its write when its run is cancelled.
nonisolated private final class WriteGate: Sendable {
  private let state = Mutex((holding: false, released: false))

  var isHolding: Bool { state.withLock { $0.holding } }

  func hold() {
    state.withLock { $0.holding = true }
    while !state.withLock({ $0.released }) { Thread.sleep(forTimeInterval: 0.005) }
  }

  func release() {
    state.withLock { $0.released = true }
  }
}
