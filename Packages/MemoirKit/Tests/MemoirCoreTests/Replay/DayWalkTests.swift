import Foundation
import ShadowCore
import Testing

@testable import MemoirCore

@Suite("Memoir replay day walk", TestTimeLimit.quick)
struct DayWalkTests {
  private typealias Fixture = ReplayFixture

  private static func date(_ text: String) throws -> LocalDate { try MemoirStoreFixture.date(text) }

  private static func stamp(_ instant: String, offsetMinutes: Int = 0) throws -> IssueStamp {
    let millis = try Fixture.millis(instant)
    return IssueStamp(instantMillis: millis, utcOffsetMinutes: offsetMinutes, issuedOn: try MemoirCommand.localDate(instantMillis: millis, utcOffsetMinutes: offsetMinutes))
  }

  private static func closedDays(_ state: ReplayState) -> [String] {
    state.days.values.filter(\.isClosed).map(\.date.isoString).sorted()
  }

  private static func create(at instant: String = "2026-03-09T06:00:00Z") throws -> MemoirCommand {
    try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: instant)
  }

  @Test func shouldCloseEveryDayBeforeTheCommandsOwnBeforeItsHandlerRuns() throws {
    let complete = try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-12")), at: "2026-03-12T08:10:00Z")
    let state = Replay.run(try Fixture.entries([try Self.create(), complete]))
    #expect(Self.closedDays(state) == ["2026-03-09", "2026-03-10", "2026-03-11"])
    #expect(state.openDay == (try Self.date("2026-03-12")))
    #expect(state.days[try Self.date("2026-03-12")]?.isOpen == true)
    #expect(state.logs[try Fixture.occurrence("2026-03-11")]?.state == .missed)
    #expect(state.logs[try Fixture.occurrence("2026-03-12")]?.state == .completed)
    #expect(state.streak(of: Fixture.quest).currentDays == 1, "the misses broke the run before the completion counted")
  }

  @Test func shouldWalkBeforeARefusedCommandButNotBeforeOneThatHalts() throws {
    let refused = try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-11", of: Fixture.secondQuest)), at: "2026-03-11T08:00:00Z")
    let walked = Replay.run(try Fixture.entries([try Self.create(), refused]))
    #expect(walked.outcomes[refused.id] == .refused(.questNotFound))
    #expect(Self.closedDays(walked) == ["2026-03-09", "2026-03-10"])

    let newer = try Fixture.command(3, .receiptScan(ReceiptScan()), at: "2026-03-14T08:00:00Z", rulesetVersion: 2)
    let halted = Replay.run(try Fixture.entries([try Self.create(), newer]))
    #expect(halted.halt == .rulesetUnavailable(command: newer.id, version: 2))
    #expect(Self.closedDays(halted).isEmpty, "a command this app cannot judge moves no day")
    var walkedAfterHalt = halted
    Replay.walk(&walkedAfterHalt, through: try Self.stamp("2026-03-20T08:00:00Z"))
    #expect(walkedAfterHalt == halted)
  }

  @Test func shouldCloseEachDayUnderTheHighestRulesetVersionSeen() throws {
    let state = Replay.run(try Fixture.entries([try Self.create()]), through: try Self.stamp("2026-03-11T08:00:00Z"))
    #expect(state.days.values.allSatisfy { $0.rulesetVersion == Ruleset.v1.version })
    #expect(state.logs[try Fixture.occurrence("2026-03-10")]?.rulesetVersion == Ruleset.v1.version)
  }

  @Test func shouldCloseDaysUpToTheHorizonAndNeverWalkBack() throws {
    let entries = try Fixture.entries([try Self.create()])
    let horizon = try Self.stamp("2026-03-12T08:00:00Z")
    let walked = Replay.run(entries, through: horizon)
    #expect(Self.closedDays(walked) == ["2026-03-09", "2026-03-10", "2026-03-11"])
    #expect(walked.openDay == horizon.issuedOn)
    var rewound = walked
    Replay.walk(&rewound, through: try Self.stamp("2026-03-10T08:00:00Z"))
    #expect(rewound == walked, "a horizon behind the open day changes nothing")
    var again = walked
    Replay.walk(&again, through: horizon)
    #expect(again == walked, "walking to the same day twice closes nothing twice")
    var stepped = Replay.run(entries)
    Replay.walk(&stepped, through: horizon)
    #expect(stepped == walked, "the horizon is applied after every command")
  }

  @Test func shouldLeaveTheStateUnchangedForACommandThatSortsBeforeTheLatest() throws {
    let complete = try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-11")), at: "2026-03-11T08:10:00Z")
    var state = Replay.run([try Fixture.entry(try Self.create(), wall: 1), try Fixture.entry(complete, wall: 10)])
    let before = state
    let late = try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-03-10")), at: "2026-03-10T08:10:00Z")
    #expect(Replay.step(try Fixture.entry(late, wall: 5, replica: Fixture.replicaB), to: &state) == .outOfOrder)
    #expect(state == before)
    #expect(Replay.step(try Fixture.entry(complete, wall: 10), to: &state) == .ignored)
    #expect(Replay.step(try Fixture.entry(try Self.create(), wall: 1), to: &state) == .ignored, "a command taken in earlier is ignored, not out of order")
    #expect(state == before)
    #expect(Replay.step(try Fixture.entry(complete, wall: 11), to: &state) == .ignored, "a command already taken in is not taken again")
  }

  @Test func shouldExtendAStateOnlyWithCommandsThatSortAfterIt() throws {
    let create = try Fixture.entry(try Self.create(), wall: 1)
    let complete = try Fixture.entry(try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-11")), at: "2026-03-11T08:10:00Z"), wall: 10)
    let late = try Fixture.entry(try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-03-10")), at: "2026-03-10T08:10:00Z"), wall: 5)
    let horizon = try Self.stamp("2026-03-12T08:00:00Z")
    let checkpoint = Replay.run([create])
    #expect(try Replay.extend(checkpoint, with: [complete, create], through: horizon) == Replay.run([create, complete], through: horizon))
    let ahead = Replay.run([create, complete])
    #expect(throws: ReplayOrderError.outOfOrder(late.position)) { try Replay.extend(ahead, with: [late]) }
    #expect(try Replay.extend(ahead, with: [create, complete]) == ahead, "commands already taken in are ignored wherever they sort")
  }

  /// A completion made on time on another device and delivered after this one closed the day: its clock places it before the close, so the full replay
  /// recomputes the day it falls into.
  @Test func shouldRecomputeAClosedDayWhenACommandClockedBeforeItsCloseArrivesLate() throws {
    let create = try Fixture.entry(try Self.create(), wall: 1)
    let later = try Fixture.entry(try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-11")), at: "2026-03-11T08:10:00Z"), wall: 10)
    let onTime = try Fixture.entry(try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-03-10")), at: "2026-03-10T08:10:00Z"), wall: 5, replica: Fixture.replicaB)
    let before = Replay.run([create, later])
    let day = try Self.date("2026-03-10")
    #expect(before.logs[try Fixture.occurrence("2026-03-10")]?.state == .missed)
    #expect(before.days[day]?.missedCount == 1)

    let after = Replay.run([create, later, onTime])
    #expect(after.logs[try Fixture.occurrence("2026-03-10")]?.state == .completed)
    #expect(after.days[day]?.missedCount == 0)
    #expect(after.days[day]?.hp?.spent == 0)
    #expect(after.streak(of: Fixture.quest).currentDays == 2, "the late completion kept the run the miss had broken")
    #expect(after.compassion.recoveries[try Self.date("2026-03-11")] == nil, "the miss that spawned a Recovery quest never happened")
  }

  /// Issued after the day closed, as the reference's offline completion: the user's outcome replaces the system miss, and the closed day keeps its HP.
  @Test func shouldLetAnOutcomeIssuedAfterTheCloseReplaceTheMissWithoutRecomputingTheDay() throws {
    let offline = try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-10")), at: "2026-03-11T08:10:00Z")
    let state = Replay.run(try Fixture.entries([try Self.create(), offline]))
    let day = try Self.date("2026-03-10")
    let log = try #require(state.logs[try Fixture.occurrence("2026-03-10")])
    #expect(log.state == .late)
    #expect(log.id == derivedID(ReplayState.missedLogDomain, "\(Fixture.quest.lowercasedString)|2026-03-10"), "the row keeps the miss's identity")
    #expect(state.days[day]?.missedCount == 1)
    #expect(state.days[day]?.hp?.spent == Ruleset.v1.intensityModes[.standard].hpCost.perBreak)
  }

  @Test func shouldChargeAnOccurrenceOnceAndWriteNoMissBesideAUsersBreak() throws {
    let skip = try Fixture.command(2, .questSkip(QuestBreak(occurrence: try Fixture.occurrence("2026-03-10"))), at: "2026-03-10T08:00:00Z")
    let state = Replay.run(try Fixture.entries([try Self.create(), skip]), through: try Self.stamp("2026-03-11T08:00:00Z"))
    let day = try #require(state.days[try Self.date("2026-03-10")])
    #expect(state.logs[try Fixture.occurrence("2026-03-10")]?.state == .skipped)
    #expect(day.missedCount == 0)
    #expect(day.hp?.spent == Ruleset.v1.intensityModes[.standard].hpCost.perBreak)
    #expect(state.hero.event(forKey: "crownforfeit_\(skip.id.lowercasedString)") != nil)
  }

  @Test func shouldCloseAtMostTheCatchUpLimitAndStrandTheOldOpenDay() throws {
    let state = Replay.run(try Fixture.entries([try Self.create()]), through: try Self.stamp("2026-09-25T08:00:00Z"))
    let closed = Self.closedDays(state)
    #expect(closed.count == ReplayState.catchUpLimitDays)
    #expect(closed.first == "2026-06-27")
    #expect(state.days[try Self.date("2026-03-09")]?.isOpen == true, "the day open before the absence is never closed")
    #expect(state.logs.count == ReplayState.catchUpLimitDays)
  }

  /// The catch-up limit counts back from the day the zone in force reached, as the reference reads today in the account's zone before it promotes the
  /// staged one (`rollover.service.ts:155,177`).
  @Test func shouldCountTheCatchUpLimitFromTheReplacedZonesDayAfterAForwardChange() throws {
    let commands = [
      try Fixture.command(1, .accountSetTimeZone(try TimeZoneChange(identifier: "UTC")), at: "2026-03-09T08:00:00Z"),
      try Self.create(at: "2026-03-09T08:01:00Z"),
      try Fixture.command(3, .accountSetTimeZone(try TimeZoneChange(identifier: "Pacific/Kiritimati")), at: "2026-03-09T09:00:00Z"),
    ]
    let state = Replay.run(try Fixture.entries(commands), through: try Self.stamp("2026-09-25T11:00:00Z", offsetMinutes: 840))
    let closed = Self.closedDays(state)
    #expect(closed.count == ReplayState.catchUpLimitDays)
    #expect(closed.first == "2026-06-27")
    #expect(closed.last == "2026-09-24")
    #expect(state.days[try Self.date("2026-09-25")] == nil, "the date the change jumps is never lived")
    #expect(state.openDay == (try Self.date("2026-09-26")))
    #expect(state.settings.timeZone(on: try Self.date("2026-09-26")) == "Pacific/Kiritimati")
  }

  /// Offsets change within a zone at a DST transition; days follow the recorded local dates, so none is skipped or closed twice.
  @Test func shouldWalkThroughDaylightSavingTransitionsByTheRecordedDates() throws {
    let spring = [
      try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: "2026-03-28T08:00:00Z", offsetMinutes: 60),
      try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-03-28")), at: "2026-03-28T22:30:00Z", offsetMinutes: 60),
      try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-03-29")), at: "2026-03-29T21:30:00Z", offsetMinutes: 120),
      try Fixture.command(4, .questComplete(try Fixture.occurrence("2026-03-30")), at: "2026-03-29T22:30:00Z", offsetMinutes: 120),
    ]
    let autumn = [
      try Fixture.command(1, Fixture.create(schedule: try Fixture.routine()), at: "2026-10-24T08:00:00Z", offsetMinutes: 120),
      try Fixture.command(2, .questComplete(try Fixture.occurrence("2026-10-25")), at: "2026-10-25T22:30:00Z", offsetMinutes: 60),
      try Fixture.command(3, .questComplete(try Fixture.occurrence("2026-10-26")), at: "2026-10-25T23:30:00Z", offsetMinutes: 60),
    ]
    #expect(spring.map(\.issuedOn.isoString) == ["2026-03-28", "2026-03-28", "2026-03-29", "2026-03-30"])
    #expect(autumn.map(\.issuedOn.isoString) == ["2026-10-24", "2026-10-25", "2026-10-26"])
    let walks = [(spring, ["2026-03-28", "2026-03-29"], "2026-03-30", [String]()), (autumn, ["2026-10-24", "2026-10-25"], "2026-10-26", ["2026-10-24"])]
    for (commands, closed, open, missed) in walks {
      let state = Replay.run(try Fixture.entries(commands))
      #expect(Self.closedDays(state) == closed)
      #expect(state.openDay == (try Self.date(open)))
      #expect(state.logs.all.filter { $0.value.state == .missed }.map(\.occurrence.date.isoString) == missed)
    }
  }

  /// A device that has not yet promoted the new zone stamps the old one; the walk then lives the change's first day and closes it in the new zone.
  @Test func shouldLiveTheFirstDayOfAForwardChangeWhenTheDriverStillStampsTheOldZone() throws {
    let commands = [
      try Fixture.command(1, .accountSetTimeZone(try TimeZoneChange(identifier: "UTC")), at: "2026-03-09T08:00:00Z"),
      try Self.create(at: "2026-03-09T08:01:00Z"),
      try Fixture.command(3, .accountSetTimeZone(try TimeZoneChange(identifier: "Pacific/Kiritimati")), at: "2026-03-09T09:00:00Z"),
      try Fixture.command(4, .receiptScan(ReceiptScan()), at: "2026-03-10T11:00:00Z"),
      try Fixture.command(5, .receiptScan(ReceiptScan()), at: "2026-03-10T12:00:00Z", offsetMinutes: 840),
    ]
    let state = Replay.run(try Fixture.entries(commands))
    #expect(Self.closedDays(state) == ["2026-03-09", "2026-03-10"])
    #expect(state.openDay == (try Self.date("2026-03-11")))
  }

  /// The forward change's skip and the backward change's held day both come from the offset the staged change was issued under, never zone data.
  @Test func shouldSkipTheDateAForwardChangeJumpsAndHoldTheDayABackwardChangeStretches() throws {
    let forward = [
      try Fixture.command(1, .accountSetTimeZone(try TimeZoneChange(identifier: "UTC")), at: "2026-03-09T08:00:00Z"),
      try Self.create(at: "2026-03-09T08:01:00Z"),
      try Fixture.command(3, .accountSetTimeZone(try TimeZoneChange(identifier: "Pacific/Kiritimati")), at: "2026-03-09T09:00:00Z"),
    ]
    let skipped = Replay.run(try Fixture.entries(forward), through: try Self.stamp("2026-03-10T11:00:00Z", offsetMinutes: 840))
    #expect(Self.closedDays(skipped) == ["2026-03-09"])
    #expect(skipped.days[try Self.date("2026-03-10")] == nil)
    #expect(skipped.logs[try Fixture.occurrence("2026-03-10")] == nil, "a date never lived is never missed")
    #expect(skipped.openDay == (try Self.date("2026-03-11")))

    let backward = [
      try Fixture.command(1, .accountSetTimeZone(try TimeZoneChange(identifier: "Pacific/Kiritimati")), at: "2026-03-09T20:00:00Z", offsetMinutes: 840),
      try Self.create(at: "2026-03-09T20:01:00Z"),
      try Fixture.command(3, .accountSetTimeZone(try TimeZoneChange(identifier: "UTC")), at: "2026-03-09T21:00:00Z", offsetMinutes: 840),
    ]
    var held = Replay.run(try Fixture.entries(backward), through: try Self.stamp("2026-03-10T11:00:00Z"))
    #expect(Self.closedDays(held) == ["2026-03-10"], "the replaced zone's day ended at its own midnight")
    #expect(held.openDay == (try Self.date("2026-03-11")))
    #expect(held.accountDay(issuedOn: try Self.date("2026-03-10")) == (try Self.date("2026-03-11")))
    let stretched = held
    Replay.walk(&held, through: try Self.stamp("2026-03-11T20:00:00Z"))
    #expect(held == stretched, "the day stays open until the new zone's date passes it")
    Replay.walk(&held, through: try Self.stamp("2026-03-12T00:00:00Z"))
    #expect(Self.closedDays(held) == ["2026-03-10", "2026-03-11"])
  }

  @Test func shouldCloseADayUnderTheIntensityInForceOnItAndOpenTheNextUnderTheChange() throws {
    let commands = [
      try Self.create(),
      try Fixture.command(2, .accountSetIntensityMode(IntensityModeChange(mode: .highIntensity)), at: "2026-03-09T09:00:00Z"),
    ]
    let state = Replay.run(try Fixture.entries(commands), through: try Self.stamp("2026-03-10T09:00:00Z"))
    #expect(state.days[try Self.date("2026-03-09")]?.intensityMode == .standard)
    #expect(state.days[try Self.date("2026-03-09")]?.hp?.hpMax == Ruleset.v1.intensityModes[.standard].hpMax)
    #expect(state.days[try Self.date("2026-03-10")]?.intensityMode == .highIntensity)
    #expect(state.days[try Self.date("2026-03-10")]?.hp?.hpMax == Ruleset.v1.intensityModes[.highIntensity].hpMax)
  }

  @Test func shouldExpireARecoveryQuestAtTheNextLocalMidnightOfTheRecordedOffset() throws {
    let anchor = try QuestSchedule(
      strictness: .anchor, startTimeMinutes: 420, durationMinutes: 30, statAffinity: .discipline,
      recurrence: try RecurrenceRule(frequency: .daily, startDate: try Self.date("2026-03-01")))
    let create = try Fixture.command(1, Fixture.create(schedule: anchor), at: "2026-03-09T03:00:00Z", offsetMinutes: 330)
    let state = Replay.run(try Fixture.entries([create]), through: try Self.stamp("2026-03-10T03:00:00Z", offsetMinutes: 330))
    let recovery = try #require(state.compassion.recoveries[try Self.date("2026-03-10")])
    #expect(recovery.state == .pending)
    #expect(recovery.expiresAtMillis == (try Fixture.millis("2026-03-10T18:30:00Z")))
    #expect(recovery.triggerLogs == [derivedID(ReplayState.missedLogDomain, "\(Fixture.quest.lowercasedString)|2026-03-09")])
  }

  @Test func shouldKeepBuiltInMetricsFixedButLetThemBeRegistered() throws {
    let steps = BuiltinMetric.steps.reference
    let commands = [
      try Fixture.command(1, .metricCreate(steps), at: "2026-03-05T08:00:00Z"),
      try Fixture.command(2, .metricUpdate(steps), at: "2026-03-05T08:01:00Z"),
      try Fixture.command(3, .metricDelete(MetricDeletion(metric: BuiltinMetric.weight.reference, detach: true)), at: "2026-03-05T08:02:00Z"),
      try Fixture.command(4, .metricRegister(MetricRegistration(metric: steps, date: try Self.date("2026-03-05"))), at: "2026-03-05T08:03:00Z"),
    ]
    let state = Replay.run(try Fixture.entries(commands))
    #expect(commands.map { state.outcomes[$0.id] } == [.superseded, .refused(.builtinMetric), .refused(.builtinMetric), .applied])
    #expect(ReplayRefusal.builtinMetric.referenceCode == "MET_003")
    #expect(state.records.metrics.isEmpty)
  }
}
