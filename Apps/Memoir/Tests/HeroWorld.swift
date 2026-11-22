import Foundation
import MemoirCore
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

/// A vault in UTC on a hand-moved clock, with the writes that earn coins, titles and cosmetics through replay rather than by setting them.
@MainActor
struct HeroWorld {
  let clock: TestClock
  let opened: MemoirOpenedVault
  let context: MemoirScreenContext
  private let farFuture = Flag()

  init() async throws {
    let clock = TestClock(day: 0, minute: 360)
    let farFuture = farFuture
    let memoir = MemoirClock(now: { farFuture.isSet ? Date(timeIntervalSince1970: 1e12) : clock.now() }, deviceZone: { TestClock.utc })
    self.clock = clock
    opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: memoir)
    context = MemoirScreenContext(opened)
    try await context.writer.issue(try TestQuests.zone("UTC"))
  }

  /// A clock in the year 33658, past every date Memoir can record, so a write fails after the screens' own checks.
  func breakTheClock() {
    farFuture.set()
  }

  func walk(to day: Int, minute: Int = 360) async throws {
    clock.set(day: day, minute: minute)
    try await opened.projection.refresh(opened.stores.main)
  }

  func createQuests(_ names: [String], strictness: Strictness, from day: Int = 0) async throws -> [UUID] {
    let quests = try names.map { name in
      let record = QuestRecord(id: UUID(), name: name)
      let schedule = try QuestSchedule(
        strictness: strictness, startTimeMinutes: 480, durationMinutes: 30, statAffinity: .body,
        recurrence: try RecurrenceRule(frequency: .daily, startDate: TestClock.day(day)))
      return (record: record, body: MemoirCommandBody.questCreate(QuestCreation(questId: record.id, schedule: schedule)))
    }
    try await context.writer.write { issuer, transaction in
      for quest in quests {
        try issuer.issue(quest.body, content: quest.record, in: &transaction)
        try quest.record.create(in: &transaction)
      }
    }
    return quests.map(\.record.id)
  }

  func complete(_ quests: [UUID], on day: Int) async throws {
    clock.set(day: day, minute: 490)
    try await context.writer.write { issuer, transaction in
      for quest in quests { try issuer.issue(.questComplete(Occurrence(quest: quest, date: TestClock.day(day))), in: &transaction) }
    }
  }

  func commands() async throws -> [MemoirCommandBody] {
    try await context.stores.commands().map { try MemoirCommandBody($0) }
  }

  /// Enough coins for a theme: forty anchors kept on time pay two coins each.
  func earnCoins() async throws {
    let anchors = try await createQuests((1...40).map { "Anchor \($0)" }, strictness: .anchor)
    try await complete(anchors, on: 0)
  }

  /// The Returner ritual: a quest kept, eight days away, then kept again, which earns the Returner title and the Returner theme.
  func returnAfterABreak() async throws {
    let run = try await createQuests(["Run"], strictness: .routine)
    try await complete(run, on: 0)
    try await walk(to: 8)
    try await complete(run, on: 8)
  }
}

nonisolated final class Flag: Sendable {
  private let value = Mutex(false)

  var isSet: Bool { value.withLock { $0 } }

  func set() {
    value.withLock { $0 = true }
  }
}

/// A defaults suite of the test's own, removed when the test's suite instance goes away.
nonisolated final class ScratchDefaults {
  let defaults: UserDefaults
  private let suite = "com.shadow.apps.memoir.tests.\(UUID().uuidString)"

  init() {
    defaults = UserDefaults(suiteName: suite)!
  }

  deinit {
    defaults.removePersistentDomain(forName: suite)
  }
}

@MainActor
func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
  try await TestClock.until(what) { condition() }
}
