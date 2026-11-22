import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir Today board", TestTimeLimit.quick)
struct TodayBoardTests {
  private typealias Device = ReadsDevice

  @Test func shouldListEachOccurrenceByPlannedStartWithItsStateAndTheActionsReplayTakes() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    let complete = try await device.issue(.questComplete(Occurrence(quest: Device.anchor, date: Device.day(0))), on: Device.day(0), minute: 425)
    try await device.walk(to: Device.day(0))
    let board = try await device.board(Device.day(0))

    #expect(board.relation == .today && board.openDay == Device.day(0))
    #expect(board.occurrences.map(\.quest.id) == [Device.anchor, Device.routine, Device.goal, Device.optional], "by start, an all-day quest last, then creation")
    #expect(board.occurrences.map(\.quest.name) == ["Morning pages", "Run", "Budget review", "Stretch"])
    let anchor = try board.occurrence(of: Device.anchor)
    #expect(anchor.status == .recorded(.completed) && anchor.log?.id == complete.id)
    #expect(anchor.log?.xpAwarded == Ruleset.v1.reward.baseXP[.anchor][.onTime] && anchor.log?.coinsAwarded == Ruleset.v1.reward.baseCoins[.anchor])
    #expect(anchor.actions.complete == .unavailable(.alreadyRecorded(.completed)) && anchor.actions.skip == .unavailable(.alreadyRecorded(.completed)))
    #expect(anchor.actions.deleteLog == .available && anchor.actions.attachReason == .availableUntil(millis: complete.instantMillis + 7 * 86_400_000))
    #expect(anchor.onTimeUntilMinute == 450 && anchor.streak.currentDays == 1 && anchor.streak.unit == .days)

    let routine = try board.occurrence(of: Device.routine)
    #expect(routine.status == .open && routine.effectiveState == nil && routine.onTimeUntilMinute == 540)
    #expect([routine.actions.complete, routine.actions.partial, routine.actions.skip, routine.actions.postpone, routine.actions.reschedule].allSatisfy { $0 == .available })
    #expect(routine.actions.deleteLog == .unavailable(.nothingRecorded) && routine.actions.attachReason == .unavailable(.nothingRecorded))
    #expect(routine.breakCost == BreakCost(hp: 1, streak: .ends(atDays: 0)))
    #expect(routine.quest.recurrenceSummary == .daily(interval: 1))

    let goal = try board.occurrence(of: Device.goal)
    #expect(goal.actions.reschedule == .unavailable(.notAllowedFor(.goal)) && goal.actions.postpone == .available && goal.onTimeUntilMinute == nil)
    #expect(goal.breakCost.hp == 0)
    let optional = try board.occurrence(of: Device.optional)
    #expect(optional.actions.postpone == .unavailable(.notAllowedFor(.optional)) && optional.breakCost == BreakCost(hp: 0, streak: .untracked))
    #expect(board.tally == DayTally(board.occurrences) && board.tally.scheduled == 4 && board.tally.kept == 1 && board.tally.open == 3)
    #expect(board.summary?.hp?.hpMax == Ruleset.v1.hpMax(for: .standard) && board.changesOn == Device.day(1))

    let refused = [
      try await device.issue(.questReschedule(try QuestReschedule(occurrence: Occurrence(quest: Device.goal, date: Device.day(0)), toMinute: 600)), on: Device.day(0)),
      try await device.issue(.questPostpone(QuestBreak(occurrence: Occurrence(quest: Device.optional, date: Device.day(0)))), on: Device.day(0)),
      try await device.issue(.questComplete(Occurrence(quest: Device.anchor, date: Device.day(0))), on: Device.day(0)),
    ]
    let outcomes = try await device.outcomes()
    #expect(refused.map { outcomes[$0.id] } == [.refused(.rescheduleUnavailable), .refused(.postponeUnavailable), .superseded], "replay agrees with each block")
  }

  /// `quest-presenters.ts:73`, `quest-actions.tsx:259,266`: a closed day keeps only the log's edits, though replay would still take a late completion.
  @Test func shouldOfferOnlyTheLogEditsOnAClosedDay() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.issue(.questComplete(Occurrence(quest: Device.goal, date: Device.day(1))), on: Device.day(1), minute: 1)
    try await device.walk(to: Device.day(1))
    let past = try await device.board(Device.day(0))
    let routine = try past.occurrence(of: Device.routine)

    #expect(past.relation == .past && routine.status == .recorded(.missed) && routine.effectiveState == .missed)
    let outcomes = [routine.actions.complete, routine.actions.partial, routine.actions.skip, routine.actions.postpone, routine.actions.reschedule]
    #expect(outcomes.allSatisfy { $0 == .unavailable(.dayPassed) })
    let created = try #require(routine.log?.createdAtMillis)
    #expect(routine.actions.attachReason == .availableUntil(millis: created + 7 * 86_400_000) && routine.actions.deleteLog == .available)
    #expect(routine.actions.attachReason.isPossible(at: created + 7 * 86_400_000) && !routine.actions.attachReason.isPossible(at: created + 7 * 86_400_000 + 1))
    #expect(past.lock.lock == .unavailable(.notAccountDay) && past.comingBack == nil)

    let tooLate = try await device.issue(
      .questAttachReason(try QuestReason(occurrence: Occurrence(quest: Device.routine, date: Device.day(0)), reasonTag: .travel, hasNote: false)), on: Device.day(8))
    #expect(try await device.outcomes()[tooLate.id] == .refused(.editWindowClosed), "replay closes the window the board reports")
  }

  @Test func shouldRefuseAnOutcomeForADayNotBegunButLetItBeRescheduled() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.walk(to: Device.day(0))
    let future = try await device.board(Device.day(2))
    let routine = try future.occurrence(of: Device.routine)

    #expect(future.relation == .future && routine.status == .upcoming && future.summary == nil)
    #expect(routine.actions.complete == .unavailable(.notYetBegun) && routine.actions.postpone == .unavailable(.notYetBegun))
    #expect(routine.actions.reschedule == .available)
    let complete = try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(2))), on: Device.day(0))
    let move = try await device.issue(.questReschedule(try QuestReschedule(occurrence: Occurrence(quest: Device.routine, date: Device.day(2)), toMinute: 600)), on: Device.day(0))
    let outcomes = try await device.outcomes()
    #expect(outcomes[complete.id] == .refused(.notStarted(Device.day(2))) && outcomes[move.id] == .applied)
  }

  /// `quest-commands.service.ts:65-66`: two reschedules of a quest dated in the seven days ending on the occurrence; past the cap an accepted one is a
  /// postpone and an unaccepted one is handed back.
  @Test func shouldHoldTheRescheduleCapOverTheSevenDaysEndingOnTheOccurrence() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    for day in 0...1 {
      try await device.issue(
        .questReschedule(try QuestReschedule(occurrence: Occurrence(quest: Device.routine, date: Device.day(day)), toMinute: 600)), on: Device.day(day), minute: 300)
    }
    try await device.walk(to: Device.day(2))
    let budget = RescheduleBudget(used: 2, cap: 2, bookedAhead: 0, freesOn: Device.day(7))
    let today = try await device.board(Device.day(2)).occurrence(of: Device.routine)
    #expect(today.reschedule == budget && today.actions.reschedule == .needsConfirmation(.rescheduleBecomesPostpone(budget)))
    let later = try await device.board(Device.day(4)).occurrence(of: Device.routine)
    #expect(later.actions.reschedule == .unavailable(.rescheduleCapReached(budget)), "a later day cannot fall back to a postpone, which needs the day begun")
    #expect(try await device.board(Device.day(7)).occurrence(of: Device.routine).actions.reschedule == .available)

    let moved = try await device.board(Device.day(1)).occurrence(of: Device.routine)
    #expect(moved.status == .recorded(.rescheduled) && moved.plannedMinute == 600 && moved.effectiveState == .missed)
    #expect(moved.actions.reschedule == .unavailable(.dayPassed))

    let rejected = try await device.issue(
      .questReschedule(try QuestReschedule(occurrence: Occurrence(quest: Device.routine, date: Device.day(2)), toMinute: 700)), on: Device.day(2))
    #expect(try await device.outcomes()[rejected.id] == .rejected(.rescheduleCap))
    let accepted = try await device.issue(
      .questReschedule(try QuestReschedule(occurrence: Occurrence(quest: Device.routine, date: Device.day(2)), toMinute: 700, acceptBeyondCap: true)), on: Device.day(2))
    #expect(try await device.outcomes()[accepted.id] == .applied)
    #expect(try await device.board(Device.day(2)).occurrence(of: Device.routine).status == .recorded(.postponed))
  }

  @Test func shouldSayARescheduledOccurrenceWasMovedAndStaysCompletable() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.issue(
      .questReschedule(try QuestReschedule(occurrence: Occurrence(quest: Device.anchor, date: Device.day(0)), toMinute: 900)), on: Device.day(0), minute: 300)
    try await device.walk(to: Device.day(0))
    let anchor = try await device.board(Device.day(0)).occurrence(of: Device.anchor)
    #expect(anchor.status == .recorded(.rescheduled) && anchor.plannedMinute == 900 && anchor.effectiveState == .rescheduled)
    #expect(anchor.actions.reschedule == .unavailable(.alreadyRescheduled) && anchor.actions.complete == .available)
    #expect(anchor.onTimeUntilMinute == 450, "the timing band reads the quest's own start, as the reference does")
  }

  @Test func shouldConfirmAPostponeThatBreaksTodaysLockAndOfferTheLockOnlyOnTheOpenDay() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.issue(.planSetLock(try PlanLock(locking: [Device.anchor, Device.routine])), on: Device.day(0), minute: 300)
    try await device.walk(to: Device.day(0))
    let board = try await device.board(Device.day(0))

    #expect(board.lock.state == .active && board.lock.quests == [Device.anchor, Device.routine])
    let state = Replay.run(try await device.store.read { transaction in try Replay.commands(in: transaction) }, through: device.horizon.function())
    #expect(board.lock.lock == .available && board.lock.unlock == .available)
    #expect(board.lock.capacity == state.lockCapacity(on: Device.day(0), plannedLoad: 4, ruleset: .v1), "the capacity replay measures the lock against")
    let locked = try board.occurrence(of: Device.routine)
    #expect(locked.locked && locked.actions.postpone == .needsConfirmation(.breaksPlanLock))
    #expect(try board.occurrence(of: Device.goal).actions.postpone == .available)
    #expect(try await device.board(Device.day(1)).lock.lock == .unavailable(.notAccountDay))
    #expect(try await device.load(QuestList.self, QuestListQuery()).entries.filter(\.lockedToday).map(\.id) == [Device.anchor, Device.routine])
    #expect(try await device.load(QuestDetail.self, QuestDetailQuery(quest: Device.anchor)).scheduleEdit == .unavailable(.lockedInTodaysPlan))

    try await device.issue(.questPostpone(QuestBreak(occurrence: Occurrence(quest: Device.routine, date: Device.day(0)))), on: Device.day(0))
    let broken = try await device.board(Device.day(0))
    #expect(try broken.lock.state == .broken && !broken.occurrence(of: Device.anchor).locked)
    #expect(try await device.load(QuestDetail.self, QuestDetailQuery(quest: Device.anchor)).scheduleEdit == .available)
  }

  @Test func shouldSayNothingCanBeLockedOnADayWithoutScheduledQuests() async throws {
    let device = try Device()
    let weekly = try RecurrenceRule(frequency: .weekly([.monday]), startDate: Device.monday)
    try await device.create(Device.routine, "Weekly review", schedule: try Device.schedule(.routine, start: 480, recurrence: weekly))
    try await device.walk(to: Device.day(1))
    let board = try await device.board(Device.day(1))
    #expect(board.occurrences.isEmpty && board.lock.lock == .unavailable(.nothingToLock) && board.lock.unlock == .unavailable(.notLocked))
    #expect(board.nextScheduled == NextOccurrence(quest: Device.routine, name: "Weekly review", date: Device.day(7)), "fixture-provider.ts:331-337")
  }

  @Test func shouldSayAShieldBridgesTheBreakAndThatAGentleDayCostsNoHP() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    for day in 0..<7 { try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(day))), on: Device.day(day), minute: 490) }
    try await device.issue(.accountSetIntensityMode(IntensityModeChange(mode: .lowIntensity)), on: Device.day(6), minute: 500)
    try await device.walk(to: Device.day(6))
    let today = try await device.board(Device.day(6)).occurrence(of: Device.routine)
    #expect(today.streak.currentDays == 7 && today.streak.shields == 1 && today.breakCost == BreakCost(hp: 1, streak: .bridgedByShield(shieldsLeft: 0)))
    let tomorrow = try await device.board(Device.day(7)).occurrence(of: Device.routine)
    #expect(tomorrow.intensityMode == .lowIntensity && tomorrow.breakCost.hp == 0, "the staged change governs the next day")
  }

  @Test func shouldOfferTheDaysRecoveryQuestOnlyWhilePendingAndOnItsDay() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.walk(to: Device.day(1))
    let board = try await device.board(Device.day(1))
    let recovery = try #require(board.recovery)
    #expect(recovery.state == .pending && recovery.sourceQuest == Device.anchor && recovery.sourceName == "Morning pages" && recovery.complete == .available)
    #expect(board.comingBack == .recovery && board.summary?.comeback.armed == true)
    #expect(try await device.board(Device.day(0)).recovery == nil)

    try await device.issue(.recoveryComplete(RecoveryCompletion()), on: Device.day(1))
    let after = try await device.board(Device.day(1))
    #expect(after.recovery?.complete == .unavailable(.recoveryClosed(.completed)) && after.comingBack == .comeback)
  }

  /// `hero-standing.service.ts:64-77`: the share of the Crown's granted XP its breaks left standing.
  @Test func shouldReportTheCrownKeptSoFarAsTheRemainderOfTheGrant() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.issue(.questSkip(QuestBreak(occurrence: Occurrence(quest: Device.routine, date: Device.day(0)))), on: Device.day(0))
    try await device.walk(to: Device.day(0))
    let crown = try #require(try await device.board(Device.day(0)).summary?.crown)
    let rules = Ruleset.v1
    let expected = rules.recomputeCrownDay(weights: [.anchor, .routine, .goal, .optional].map(rules.crownWeight(for:)), forfeited: [rules.crownWeight(for: .routine)])
    #expect(crown.granted.xp == expected.grantedXP && crown.remaining.xp == expected.remainingXP)
    #expect(crown.keptPercent == Fraction(numerator: expected.remainingXP * 100, denominator: expected.grantedXP)?.roundedHalfUp)
    #expect(crown.keptPercent < 100 && crown.dayIndex == 1 && crown.dayCount == 1 && crown.cadence == .daily)
  }

  @Test func shouldShowALoggedOccurrenceOfAQuestDeletedSinceWithItsActionsClosed() async throws {
    let device = try Device()
    try await device.createStandardQuests()
    try await device.issue(.questComplete(Occurrence(quest: Device.goal, date: Device.day(0))), on: Device.day(0))
    try await device.issue(.questDelete(QuestReference(questId: Device.goal)), on: Device.day(0))
    try await device.walk(to: Device.day(1))
    let deleted = try await device.board(Device.day(0)).occurrence(of: Device.goal)
    #expect(!deleted.isScheduled && !deleted.quest.isActive && deleted.status == .recorded(.completed))
    #expect(deleted.actions.complete == .unavailable(.questInactive) && deleted.actions.deleteLog == .available)
    #expect(try await device.board(Device.day(1)).occurrences.allSatisfy { $0.quest.id != Device.goal })
  }

  @Test func shouldListAQuestWhoseWordsHaveNotArrivedWithoutAName() async throws {
    let device = try Device()
    try await device.create(Device.routine, nil, schedule: try Device.schedule(.routine, start: 480))
    try await device.walk(to: Device.day(0))
    let routine = try await device.board(Device.day(0)).occurrence(of: Device.routine)
    #expect(routine.quest.name == nil && routine.status == .open)
  }

  @Test func shouldReadAnEmptyBoardBeforeAnyCommand() async throws {
    let device = try Device()
    let board = try await device.board(Device.day(0))
    #expect(board.openDay == nil && board.occurrences.isEmpty && board.summary == nil && board.changesOn == nil && board.halt == nil)
  }
}
