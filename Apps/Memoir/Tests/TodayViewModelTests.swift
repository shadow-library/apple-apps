import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("TodayViewModel", TestTimeLimit.standard)
struct TodayViewModelTests {
  @Test("should load the account's day with its quests, the hero and the streaks")
  func loadsTheBoard() async throws {
    let world = try await TodayTestWorld()
    let walk = try await world.quest("Walk")
    try await world.start()
    defer { world.stop() }

    let row = try await world.row(walk, until: "the quest's row")
    let snapshot = try world.snapshot
    #expect(snapshot.today == MemoirToday(date: TestClock.day0, source: .account("UTC")))
    #expect(snapshot.board.date == TestClock.day0)
    #expect(row.quest.name == "Walk")
    #expect(row.status == .open)
    #expect(snapshot.content == .quests)
    #expect(snapshot.hasActiveQuests)
    #expect(snapshot.hero.level.level == 1)
    #expect(snapshot.streaks.entries.map(\.quest) == [walk])
    #expect(snapshot.tomorrow.map(\.occurrence) == [Occurrence(quest: walk, date: TestClock.day(1))])
    #expect(snapshot.notices.isEmpty)
  }

  @Test("should show an action's outcome once it is written")
  func reEmitsAfterAnAction() async throws {
    let world = try await TodayTestWorld()
    let walk = try await world.quest("Walk")
    try await world.start()
    defer { world.stop() }
    _ = try await world.row(walk, until: "the quest's row")

    #expect(await world.model.perform(.complete(Occurrence(quest: walk, date: TestClock.day0))) == .done(offersUndo: false))

    let row = try await world.row(walk, until: "the completion") { $0.status != .open }
    #expect(row.status == .recorded(.late), "noon is past the 08:00 window")
    #expect(try world.snapshot.board.tally.kept == 1)
    #expect(try world.snapshot.hero.level.totalXP > 0)
  }

  @Test("should move to the new day when the day turns, with yesterday's open quest missed")
  func reEmitsAtADayTurn() async throws {
    let world = try await TodayTestWorld()
    let walk = try await world.quest("Walk")
    try await world.start()
    defer { world.stop() }
    _ = try await world.row(walk, until: "the quest's row")

    try await world.turn(to: 1)

    let snapshot = try world.snapshot
    #expect(snapshot.board.date == TestClock.day(1))
    #expect(snapshot.board.occurrences.map(\.occurrence) == [Occurrence(quest: walk, date: TestClock.day(1))])
    #expect(snapshot.board.recovery?.sourceQuest == walk, "a routine miss offers a Recovery quest the next day")
    #expect(snapshot.board.comingBack == .recovery)
  }

  @Test("should offer the first quest when there is none, and the next occurrence when nothing is due")
  func showsEmptyStates() async throws {
    let world = try await TodayTestWorld()
    try await world.start()
    defer { world.stop() }
    #expect(try world.snapshot.content == .firstDay)
    #expect(try world.snapshot.hasActiveQuests == false)

    let laterThisWeek = TestClock.day(2)
    let review = try await world.quest("Review", strictness: .goal, start: nil, frequency: .weekly([laterThisWeek.weekday]))

    let model = world.model
    try await TestClock.until("nothing due") { model.snapshot?.content != .firstDay }
    guard case .nothingDue(let next?) = try world.snapshot.content else {
      Issue.record("expected the next occurrence, got \(String(describing: model.snapshot?.content))")
      return
    }
    #expect(next.quest == review && next.date == laterThisWeek && next.name == "Review")
    #expect(try world.snapshot.upcoming.isEmpty == false, "the Crown's close is still coming up")
  }

  @Test("should say when this device does not know the account's zone")
  func showsAnUnknownZone() async throws {
    let world = try await TodayTestWorld()
    try await world.start()
    defer { world.stop() }
    let body = try MemoirCommandBody(type: MemoirCommandKind.accountSetTimeZone.commandType, payload: ["timezone": .string("Mars/Olympus_Mons")], occurrence: nil)
    let instant = TestClock.millis(day: 0, minute: 721)
    try await world.append(
      try MemoirCommand(
        id: UUID.v7(at: TestClock.date(day: 0, minute: 721)), body: body, instantMillis: instant, utcOffsetMinutes: 0, issuedOn: TestClock.day0, rulesetVersion: 1))
    try await world.turn(to: 1)

    let model = world.model
    try await TestClock.until("the unknown zone notice") {
      model.snapshot?.notices.contains { if case .unknownZone("Mars/Olympus_Mons", _) = $0 { true } else { false } } == true
    }
    guard case .unknownZone(_, let offset) = try world.snapshot.today.source else {
      Issue.record("expected an unknown zone")
      return
    }
    #expect(offset == 0, "the offset the latest command recorded")
  }

  @Test("should ask for an update when replay stopped at a command this build cannot read")
  func showsAHalt() async throws {
    let world = try await TodayTestWorld()
    try await world.quest("Walk")
    try await world.start()
    defer { world.stop() }
    #expect(try world.snapshot.notices.isEmpty)

    try await world.append(
      try MemoirCommand(
        id: UUID.v7(at: TestClock.date(day: 0, minute: 721)), body: .recoveryComplete(RecoveryCompletion()), instantMillis: TestClock.millis(day: 0, minute: 721),
        utcOffsetMinutes: 0, issuedOn: TestClock.day0, rulesetVersion: 3))

    let model = world.model
    try await TestClock.until("the update notice") { model.snapshot?.notices == [.needsAppUpdate] }
  }

  @Test("should list the later quests, tomorrow's and the Crown's close as coming up")
  func listsWhatComesUp() async throws {
    let world = try await TodayTestWorld(minute: 6 * 60)
    let walk = try await world.quest("Walk", start: 18 * 60)
    try await world.start()
    defer { world.stop() }
    _ = try await world.row(walk, until: "the quest's row")

    let upcoming = try world.snapshot.upcoming
    #expect(upcoming.map(\.title) == ["Walk", "Walk", String(localized: "Crown closes", table: "Today")])
    #expect(upcoming[0].meta == String(localized: "Today", table: "Today"))
    #expect(upcoming[1].when == String(localized: "Tomorrow", table: "Today"))
  }

  @Test("should format the catalog's plural keys with their later arguments in place")
  func formatsPlurals() {
    let (kept, scheduled, partial, one) = (1, 2, 1, 1)
    #expect(String(localized: "\(kept) of \(scheduled) quests completed, \(partial) partial.", table: "Today") == "1 of 2 quests completed, 1 partial.")
    #expect(String(localized: "\(kept) of \(one) quests completed.", table: "Today") == "1 of 1 quest completed.")
    #expect(String(localized: "Today can hold about \(one) quests.", table: "Today") == "Today can hold about 1 quest.")
    #expect(String(localized: "\(scheduled) shields", table: "Today") == "2 shields")
  }

  @Test("should report the wake window only for the open day")
  func countsTheWakeWindow() async throws {
    let world = try await TodayTestWorld(minute: 21 * 60)
    try await world.quest("Walk")
    try await world.start()
    defer { world.stop() }

    #expect(world.model.minutesUntilSleep() == ScheduleWindow.standard.end - 21 * 60)
    #expect(world.model.minuteOfDay() == 21 * 60)
  }
}
