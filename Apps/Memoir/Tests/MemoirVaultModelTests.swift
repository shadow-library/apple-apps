import Foundation
import MemoirCore
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

@MainActor
@Suite("MemoirVaultModel", TestTimeLimit.standard)
struct MemoirVaultModelTests {
  @Test("should start opening and become ready with the opened stores")
  func becomesReady() async throws {
    let model = MemoirVaultModel { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in try await MemoirVaultOpener.open(.inMemory, appVersion: "1") }
    guard case .opening = model.state else {
      Issue.record("expected the model to start opening")
      return
    }

    await model.open()

    #expect(model.vault != nil)
    #expect(model.failure == nil)
  }

  @Test("should surface a failed open as its typed error and recover on retry")
  func surfacesFailureThenRecovers() async throws {
    let attempts = Attempts()
    let model = MemoirVaultModel { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in
      guard attempts.next() > 1 else { throw .locationUnavailable("no application support directory") }
      return try await MemoirVaultOpener.open(.inMemory, appVersion: "1")
    }

    await model.open()

    #expect(model.vault == nil)
    #expect(model.failure == .locationUnavailable("no application support directory"))

    await model.open()

    #expect(model.vault != nil)
    #expect(model.failure == nil)
    #expect(attempts.count == 2)
  }

  @Test("should surface a blocked vault directory as an open failure")
  func surfacesOpenFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MemoirTests-\(UUID().uuidString)")
    try Data().write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = try MemoirVault(directory: directory)
    let model = MemoirVaultModel { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in try await MemoirVaultOpener.open(.vault(vault), appVersion: "1") }

    await model.open()

    guard case .failed(.openFailed) = model.state else {
      Issue.record("expected an open failure, got \(model.state)")
      return
    }
  }

  @Test("should open once when asked twice at the same time, and keep an open vault")
  func opensOnce() async throws {
    let attempts = Attempts()
    let model = MemoirVaultModel { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in
      _ = attempts.next()
      return try await MemoirVaultOpener.open(.inMemory, appVersion: "1")
    }

    async let first: Void = model.open()
    async let second: Void = model.open()
    _ = await (first, second)
    let replica = try #require(model.vault).stores.main.replica
    await model.open()

    #expect(attempts.count == 1)
    #expect(model.vault?.stores.main.replica == replica)
  }

  @Test("should refresh the day only once the vault is open")
  func refreshesOnlyWhenOpen() async {
    let model = MemoirVaultModel { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in try await MemoirVaultOpener.open(.inMemory, appVersion: "1") }

    await model.refreshDay()

    guard case .opening = model.state else {
      Issue.record("a refresh before opening must not open the vault")
      return
    }
  }

  @Test("should walk the derived day to the wall clock's day only when the day is refreshed")
  func walksTheHorizonOnRefresh() async throws {
    let clock = AdvanceableClock(Date(timeIntervalSince1970: 1_772_366_400))
    let issueClock = IssueClock.current
    let model = MemoirVaultModel { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in
      try await MemoirVaultOpener.open(.inMemory, appVersion: "1", wallClock: clock.now)
    }
    await model.open()
    let stores = try #require(model.vault).stores
    let today = try issueClock.localDate(at: clock.millis)
    let quest = UUID()
    let schedule = try QuestSchedule(
      strictness: .routine, startTimeMinutes: 480, durationMinutes: 30, statAffinity: .body, recurrence: try RecurrenceRule(frequency: .daily, startDate: today))
    _ = try await stores.main.write { transaction in
      let record = QuestRecord(id: quest, name: "Walk")
      try record.create(in: &transaction)
      try CommandIssuer(clock: issueClock, wallClock: clock.now).issue(.questCreate(QuestCreation(questId: quest, schedule: schedule)), content: record, in: &transaction)
    }
    #expect(try await openDay(in: stores) == today)

    clock.advance(days: 2)
    let later = try #require(today.adding(days: 2))

    #expect(try await openDay(in: stores) == today, "nothing walks the view before the refresh")
    #expect(try await lastDay(in: stores, through: later) == today)

    await model.refreshDay()

    #expect(try await openDay(in: stores) == later)
    #expect(try await lastDay(in: stores, through: later) == later)
  }

  private func openDay(in stores: MemoirStores) async throws -> LocalDate? {
    try await stores.main.read { transaction in try MemoirDerived.hero(in: transaction)?.openDay }
  }

  private func lastDay(in stores: MemoirStores, through end: LocalDate) async throws -> LocalDate? {
    let start = try #require(end.adding(days: -7))
    return try await stores.main.read { transaction in try MemoirDerived.days(from: start, through: end, in: transaction).last?.date }
  }
}

nonisolated private final class AdvanceableClock: Sendable {
  private let current: Mutex<Date>

  init(_ start: Date) {
    current = Mutex(start)
  }

  var now: @Sendable () -> Date { { self.current.withLock { $0 } } }

  var millis: Int64 { Int64(current.withLock { $0 }.timeIntervalSince1970 * 1000) }

  func advance(days: Int) {
    current.withLock { $0 += TimeInterval(days * 86_400) }
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
