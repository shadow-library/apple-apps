import Foundation
import ShadowCore
import Testing

@testable import MemoirCore

@Suite("Memoir reminder plan", TestTimeLimit.quick)
struct ReminderPlanTests {
  private static let berlin = TimeZone(identifier: "Europe/Berlin")!
  private static let quest = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000e001")
  private static let other = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000e002")
  private static let third = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000e003")
  private static let subscription = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000e101")

  private static func date(_ text: String) -> LocalDate {
    guard let date = LocalDate(isoString: text) else { preconditionFailure("\(text) is a date") }
    return date
  }

  private static func instant(_ text: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: text) else { preconditionFailure("\(text) is an instant") }
    return date
  }

  private static func millis(_ text: String) -> Int64 {
    Int64(instant(text).timeIntervalSince1970 * 1000)
  }

  private static func zone(_ identifier: String?, openDay: String, offset: Int = 60, staged: AccountZone.Staged? = nil) -> AccountZone {
    AccountZone(inForce: identifier, openDay: date(openDay), lastRecordedOffsetMinutes: offset, staged: staged)
  }

  private static func quest(
    _ id: UUID = quest, name: String = "Run", start: Int?, lead: Int = 0, from: String, strictness: Strictness = .routine
  ) throws -> ReminderSources.Quest {
    let schedule = try QuestSchedule(
      strictness: strictness, startTimeMinutes: start, durationMinutes: 30, statAffinity: .body,
      recurrence: try RecurrenceRule(frequency: .daily, interval: 1, startDate: date(from)))
    return ReminderSources.Quest(id: id, name: name, leadMinutes: lead, schedule: schedule)
  }

  private static func sources(
    zone: AccountZone, quests: [ReminderSources.Quest] = [], inactiveQuests: [ReminderSources.Quest] = [], logs: [Occurrence: ReminderSources.Logged] = [:],
    subscriptions: [ReminderSources.Subscription] = [], confirmations: [ReminderSources.Confirmed] = [], wake: ScheduleWindow = .standard,
    halt: ReplayHalt? = nil
  ) -> ReminderSources {
    ReminderSources(
      zone: zone, wakeWindow: wake, quests: quests, inactiveQuests: inactiveQuests, logs: logs, subscriptions: subscriptions, confirmations: confirmations,
      halt: halt)
  }

  private static func settledQuest(_ quest: UUID = quest, on date: String) -> ReminderOccurrence {
    ReminderOccurrence(kind: .quest, record: quest, date: Self.date(date))
  }

  private static func logged(_ state: QuestLogState) -> ReminderSources.Logged {
    ReminderSources.Logged(state: state, rescheduledToMinute: state == .rescheduled ? 720 : nil)
  }

  private static func query(days: Int = 7, limit: Int = ReminderQuery.systemPendingLimit, device: TimeZone = berlin) throws -> ReminderQuery {
    try ReminderQuery(horizonDays: days, limit: limit, device: device)
  }

  private static func fires(_ plan: ReminderPlan) -> [Int64] {
    plan.reminders.map(\.fireAtMillis)
  }

  private static func questDates(_ plan: ReminderPlan) -> [LocalDate] {
    plan.reminders.compactMap { reminder in
      guard case .quest(let quest) = reminder.content else { return nil }
      return quest.date
    }
  }

  @Test func shouldFireTheLeadBeforeEachTimedOccurrenceWithinTheWindow() throws {
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 480, lead: 15, from: "2026-11-01")])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 2), now: Self.instant("2026-11-16T06:00:00Z"))
    #expect(Self.fires(plan) == [Self.millis("2026-11-16T06:45:00Z"), Self.millis("2026-11-17T06:45:00Z")], "07:45 in Berlin, the day after's within 48 hours")
    let first = try #require(plan.reminders.first)
    #expect(first.content == .quest(QuestReminder(quest: Self.quest, name: "Run", date: Self.date("2026-11-16"), startMinute: 480, leadMinutes: 15, isRescheduled: false)))
    #expect(first.identifier.hasPrefix(Reminder.identifierPrefix))
    #expect(first.occurrenceID == Reminder.occurrenceID(kind: .quest, record: Self.quest, date: Self.date("2026-11-16")))
    #expect(plan.changesAt == Self.instant("2026-11-16T06:45:00Z"), "the soonest fire comes before midnight")
  }

  @Test func shouldLeaveOutAFireInstantThatHasPassed() throws {
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 480, lead: 15, from: "2026-11-01")])
    let atFire = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-16T06:45:00Z"))
    #expect(Self.questDates(atFire) == [Self.date("2026-11-17")], "a reminder firing now has fired")
    let justBefore = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-16T06:44:59Z"))
    #expect(Self.questDates(justBefore) == [Self.date("2026-11-16")], "the next day's fire is past the 24-hour window")
  }

  @Test(arguments: [QuestLogState.completed, .late, .partial, .skipped, .postponed, .missed, .recovery])
  func shouldNotRemindAnOccurrenceAlreadyRecorded(_ state: QuestLogState) throws {
    let occurrence = Occurrence(quest: Self.quest, date: Self.date("2026-11-16"))
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 600, from: "2026-11-01")],
      logs: [occurrence: ReminderSources.Logged(state: state, rescheduledToMinute: nil)])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 2), now: Self.instant("2026-11-16T06:00:00Z"))
    #expect(Self.questDates(plan) == [Self.date("2026-11-17")])
  }

  @Test func shouldRemindARescheduledOccurrenceAtItsNewMinute() throws {
    let occurrence = Occurrence(quest: Self.quest, date: Self.date("2026-11-16"))
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 600, lead: 10, from: "2026-11-01")],
      logs: [occurrence: ReminderSources.Logged(state: .rescheduled, rescheduledToMinute: 1_080)])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-16T06:00:00Z"))
    let reminder = try #require(plan.reminders.first)
    #expect(reminder.fireAtMillis == Self.millis("2026-11-16T16:50:00Z"), "18:00 in Berlin, ten minutes early")
    #expect(reminder.content == .quest(QuestReminder(quest: Self.quest, name: "Run", date: occurrence.date, startMinute: 1_080, leadMinutes: 10, isRescheduled: true)))
  }

  @Test func shouldRemindAQuestWithoutATimeAtTheStartOfTheWakeWindowWithoutItsLead() throws {
    let wake = try #require(ScheduleWindow(start: 450, end: 1_380))
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: nil, lead: 30, from: "2026-11-17", strictness: .goal)], wake: wake)
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-16T12:00:00Z"))
    let reminder = try #require(plan.reminders.first)
    #expect(reminder.fireAtMillis == Self.millis("2026-11-17T06:30:00Z"), "07:30 in Berlin")
    #expect(reminder.content == .quest(QuestReminder(quest: Self.quest, name: "Run", date: Self.date("2026-11-17"), startMinute: nil, leadMinutes: 0, isRescheduled: false)))
  }

  @Test func shouldResolveTimesInsideTheSpringForwardGapAndAcrossTheTransition() throws {
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-03-28"),
      quests: [try Self.quest(start: 150, from: "2026-03-29"), try Self.quest(Self.other, name: "Swim", start: 210, lead: 90, from: "2026-03-29")])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-03-28T20:00:00Z"))
    #expect(
      Self.fires(plan) == [Self.millis("2026-03-29T00:00:00Z"), Self.millis("2026-03-29T01:00:00Z")],
      "03:30 CEST less 90 minutes is 01:00 CET; 02:30 does not exist and moves to the transition")
  }

  @Test func shouldTakeTheEarlierInstantOfARepeatedTimeWhenTheClocksGoBack() throws {
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-10-24"), quests: [try Self.quest(start: 150, lead: 0, from: "2026-10-25")])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-10-24T20:00:00Z"))
    #expect(Self.fires(plan) == [Self.millis("2026-10-25T00:30:00Z")], "02:30 CEST, the first of the two")
    let autumn = ReminderPlan.make(
      Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-10-24"), quests: [try Self.quest(start: 480, lead: 0, from: "2026-10-24")]),
      query: try Self.query(days: 2), now: Self.instant("2026-10-24T05:00:00Z"))
    #expect(Self.fires(autumn) == [Self.millis("2026-10-24T06:00:00Z"), Self.millis("2026-10-25T07:00:00Z")], "08:00 CEST, then 08:00 CET")
  }

  @Test func shouldUseAStagedZoneFromTheDayAfterTheOpenDay() throws {
    let staged = AccountZone.Staged(identifier: "America/New_York", issuedUnderOffsetMinutes: 60)
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16", staged: staged), quests: [try Self.quest(start: 540, from: "2026-11-01")])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 2), now: Self.instant("2026-11-16T06:00:00Z"))
    #expect(Self.fires(plan) == [Self.millis("2026-11-16T08:00:00Z"), Self.millis("2026-11-17T14:00:00Z")], "09:00 in Berlin on the open day, then 09:00 in New York")
    #expect(plan.changesAt == Self.instant("2026-11-16T08:00:00Z"))
    let unset = ReminderPlan.make(
      Self.sources(zone: .unset, quests: [try Self.quest(start: 540, from: "2026-11-01")]), query: try Self.query(days: 1, device: .gmt),
      now: Self.instant("2026-11-16T06:00:00Z"))
    #expect(Self.fires(unset) == [Self.millis("2026-11-16T09:00:00Z")], "the device's zone before the account has one")
  }

  @Test func shouldResolveTheEarlyMinutesOfAnEasternStagedZonesFirstDayInThatZone() throws {
    let staged = AccountZone.Staged(identifier: "Asia/Tokyo", issuedUnderOffsetMinutes: 60)
    let zone = Self.zone("Europe/Berlin", openDay: "2026-11-16", staged: staged)
    let sources = Self.sources(zone: zone, quests: [try Self.quest(start: 30, from: "2026-11-16")])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-15T23:10:00Z"))
    #expect(
      Self.fires(plan) == [Self.millis("2026-11-15T23:30:00Z"), Self.millis("2026-11-16T15:30:00Z")],
      "00:30 in Berlin on the open day, then 00:30 in Tokyo, which comes before midnight in Berlin")
    let lagging = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-16T23:10:00Z"))
    #expect(Self.fires(lagging) == [Self.millis("2026-11-17T15:30:00Z")], "the clock of now is already Tokyo's while the projection still opens the 16th")
  }

  @Test func shouldChangeWhenTheNextReminderEntersTheWindowAcrossTheLongAutumnDay() throws {
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-10-24"), quests: [try Self.quest(start: 480, from: "2026-10-01")])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-10-24T06:30:00Z"))
    #expect(plan.reminders.isEmpty, "08:00 CEST has passed and 08:00 CET on the 25th is 24 and a half hours away")
    #expect(plan.changesAt == Self.instant("2026-10-24T07:00:00Z"), "before midnight, when the 25th's fire comes within a day")
    let entered = ReminderPlan.make(sources, query: try Self.query(days: 1), now: plan.changesAt)
    #expect(Self.fires(entered) == [Self.millis("2026-10-25T07:00:00Z")])
  }

  @Test func shouldPlanNoQuestAfterAReplayHaltButKeepSubscriptions() throws {
    let halt = ReplayHalt.unknownCommandType(command: Self.other, type: "quest.future")
    let amount = MoneyAmount(amountMinor: 500, currency: try #require(CurrencyCode("EUR")))
    let due = ReminderSources.Subscription(id: Self.subscription, name: "Music", amount: amount, nextDue: Self.date("2026-11-18"), lead: .onDay)
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 600, from: "2026-11-01")], subscriptions: [due], halt: halt)
    let plan = ReminderPlan.make(sources, query: try Self.query(), now: Self.instant("2026-11-16T05:00:00Z"))
    #expect(plan.reminders.map(\.content.kind) == [.subscription] && plan.halt == halt)
  }

  @Test func shouldHoldALeadWithinTheReferenceRange() throws {
    #expect(try Self.quest(start: 600, lead: -5, from: "2026-11-01").leadMinutes == 0)
    #expect(try Self.quest(start: 600, lead: .max, from: "2026-11-01").leadMinutes == Int(Int16.max))
  }

  @Test func shouldKeepTheSoonestUpToTheLimitAndCountTheRest() throws {
    let quests = [
      try Self.quest(Self.quest, start: 600, from: "2026-11-01"), try Self.quest(Self.other, name: "Swim", start: 600, from: "2026-11-01"),
      try Self.quest(Self.third, name: "Read", start: 420, from: "2026-11-01"),
    ]
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: quests)
    let all = ReminderPlan.make(sources, query: try Self.query(days: 7), now: Self.instant("2026-11-16T05:00:00Z"))
    #expect(all.reminders.count == 21 && all.omitted == 0)
    let capped = ReminderPlan.make(sources, query: try Self.query(days: 7, limit: 4), now: Self.instant("2026-11-16T05:00:00Z"))
    #expect(capped.reminders == Array(all.reminders.prefix(4)) && capped.omitted == 17)
    #expect(Self.fires(capped) == Self.fires(capped).sorted())
    let tied = capped.reminders.filter { $0.fireAtMillis == Self.millis("2026-11-16T09:00:00Z") }
    #expect(tied.count == 2 && tied.map(\.identifier) == tied.map(\.identifier).sorted(), "a tie is broken by identifier, the same on every device")
    #expect(ReminderPlan.make(sources, query: try Self.query(limit: 0), now: Self.instant("2026-11-16T05:00:00Z")).omitted == 21)
  }

  @Test func shouldChangeTheIdentifierWhenTheFireTimeOrContentChangesButNotTheOccurrence() throws {
    let now = Self.instant("2026-11-16T05:00:00Z")
    let zone = Self.zone("Europe/Berlin", openDay: "2026-11-16")
    let base = ReminderPlan.make(Self.sources(zone: zone, quests: [try Self.quest(start: 600, lead: 10, from: "2026-11-16")]), query: try Self.query(days: 1), now: now)
    let again = ReminderPlan.make(Self.sources(zone: zone, quests: [try Self.quest(start: 600, lead: 10, from: "2026-11-16")]), query: try Self.query(days: 1), now: now)
    let lead = ReminderPlan.make(Self.sources(zone: zone, quests: [try Self.quest(start: 600, lead: 20, from: "2026-11-16")]), query: try Self.query(days: 1), now: now)
    let renamed = ReminderPlan.make(
      Self.sources(zone: zone, quests: [try Self.quest(name: "Long run", start: 600, lead: 10, from: "2026-11-16")]), query: try Self.query(days: 1), now: now)
    let first = try #require(base.reminders.first)
    #expect(again.reminders.first == first)
    for changed in [lead, renamed] {
      let reminder = try #require(changed.reminders.first)
      #expect(reminder.identifier != first.identifier && reminder.occurrenceID == first.occurrenceID)
    }
    #expect(
      Reminder.occurrenceID(kind: .quest, record: Self.quest, date: Self.date("2026-11-16"))
        != Reminder.occurrenceID(kind: .subscription, record: Self.quest, date: Self.date("2026-11-16")))
  }

  @Test func shouldDiffThePlanAgainstPendingRequestsAndLeaveForeignOnesAlone() throws {
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 600, from: "2026-11-01")])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 3), now: Self.instant("2026-11-16T05:00:00Z"))
    let kept = plan.reminders[0].identifier
    let stale = Reminder.identifierPrefix + "00000000-0000-8000-8000-000000000000"
    let diff = plan.diff(against: [kept, stale, "com.shadow.apps.memoir.other"])
    #expect(diff.add == Array(plan.reminders.dropFirst()))
    #expect(diff.remove == [stale])
    #expect(plan.diff(against: plan.identifiers).isEmpty)
    #expect(ReminderPlan.make(Self.sources(zone: .unset), query: try Self.query(), now: Self.instant("2026-11-16T05:00:00Z")).diff(against: [kept]).remove == [kept])
  }

  @Test func shouldRemindASubscriptionAtTheStartOfTheWakeWindowOnItsLeadDay() throws {
    let wake = try #require(ScheduleWindow(start: 420, end: 1_380))
    let amount = MoneyAmount(amountMinor: 1_299, currency: try #require(CurrencyCode("EUR")))
    let due = ReminderSources.Subscription(id: Self.subscription, name: "Music", amount: amount, nextDue: Self.date("2026-11-20"), lead: .threeDays)
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), subscriptions: [due], wake: wake)
    let plan = ReminderPlan.make(sources, query: try Self.query(), now: Self.instant("2026-11-16T05:00:00Z"))
    let reminder = try #require(plan.reminders.first)
    #expect(reminder.fireAtMillis == Self.millis("2026-11-17T06:00:00Z"), "07:00 in Berlin three days before")
    #expect(reminder.content == .subscription(SubscriptionReminder(subscription: Self.subscription, name: "Music", dueOn: due.nextDue, amount: amount, lead: .threeDays)))
    #expect(reminder.occurrenceID == Reminder.occurrenceID(kind: .subscription, record: Self.subscription, date: due.nextDue))
    let late = ReminderPlan.make(sources, query: try Self.query(), now: Self.instant("2026-11-18T05:00:00Z"))
    #expect(late.reminders.isEmpty, "the reminder day has passed though the charge has not")
  }

  @Test(arguments: QuestLogState.allCases)
  func shouldSettleAnOccurrenceTheOwnerLoggedButNotOneMissedOrMoved(_ state: QuestLogState) throws {
    let occurrence = Occurrence(quest: Self.quest, date: Self.date("2026-11-16"))
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 600, from: "2026-11-01")], logs: [occurrence: Self.logged(state)])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-16T12:00:00Z"))
    let settles = ![QuestLogState.missed, .rescheduled].contains(state)
    #expect(plan.settled == (settles ? [Self.settledQuest(on: "2026-11-16")] : []))
  }

  @Test func shouldSettleOnlyTodayAndYesterdayInTheZoneInForce() throws {
    let logs = Dictionary(
      uniqueKeysWithValues: ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"].map { (Occurrence(quest: Self.quest, date: Self.date($0)), Self.logged(.completed)) })
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 600, from: "2026-11-01")], logs: logs)
    let berlin = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-15T23:30:00Z"))
    #expect(berlin.settled == [Self.settledQuest(on: "2026-11-15"), Self.settledQuest(on: "2026-11-16")], "00:30 on the 16th in Berlin, still the 15th in UTC")
    let later = ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-17T09:00:00Z"))
    #expect(later.settled == [Self.settledQuest(on: "2026-11-16"), Self.settledQuest(on: "2026-11-17")])
    #expect(ReminderPlan.make(Self.sources(zone: .unset), query: try Self.query(), now: Self.instant("2026-11-16T12:00:00Z")).settled.isEmpty)
  }

  @Test func shouldSettleTheRecentOccurrencesOfAnInactiveQuestOnTheDaysItOccurs() throws {
    let everyOther = ReminderSources.Quest(
      id: Self.other, name: "Swim", leadMinutes: 0,
      schedule: try QuestSchedule(
        strictness: .routine, startTimeMinutes: 600, durationMinutes: 30, statAffinity: .body,
        recurrence: try RecurrenceRule(frequency: .daily, interval: 2, startDate: Self.date("2026-11-01"))))
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), inactiveQuests: [try Self.quest(start: 600, from: "2026-11-01"), everyOther])
    let plan = ReminderPlan.make(sources, query: try Self.query(days: 2), now: Self.instant("2026-11-16T12:00:00Z"))
    #expect(plan.reminders.isEmpty, "an inactive quest is never reminded")
    #expect(plan.settled == [Self.settledQuest(on: "2026-11-15"), Self.settledQuest(on: "2026-11-16"), Self.settledQuest(Self.other, on: "2026-11-15")])
  }

  @Test func shouldSettleASubscriptionCycleConfirmedTodayOrYesterday() throws {
    let confirmed = { (billing: String, issued: String) in
      ReminderSources.Confirmed(cycle: CycleConfirmation(subscription: Self.subscription, billingDate: Self.date(billing)), issuedOn: Self.date(issued))
    }
    let sources = Self.sources(
      zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"),
      confirmations: [confirmed("2026-10-05", "2026-10-05"), confirmed("2026-11-05", "2026-11-15"), confirmed("2026-12-05", "2026-11-16")])
    let plan = ReminderPlan.make(sources, query: try Self.query(), now: Self.instant("2026-11-16T12:00:00Z"))
    #expect(
      plan.settled == [
        ReminderOccurrence(kind: .subscription, record: Self.subscription, date: Self.date("2026-11-05")),
        ReminderOccurrence(kind: .subscription, record: Self.subscription, date: Self.date("2026-12-05")),
      ], "the cycle confirmed late yesterday and the one confirmed early today, by their due dates")
  }

  @Test func shouldNameAReminderByTheOccurrenceItsIdentifierBinds() throws {
    let sources = Self.sources(zone: Self.zone("Europe/Berlin", openDay: "2026-11-16"), quests: [try Self.quest(start: 600, from: "2026-11-01")])
    let reminder = try #require(ReminderPlan.make(sources, query: try Self.query(days: 1), now: Self.instant("2026-11-16T05:00:00Z")).reminders.first)
    #expect(reminder.occurrence == Self.settledQuest(on: "2026-11-16"))
    #expect(reminder.occurrence.id == reminder.occurrenceID)
  }

  @Test func shouldRefuseAnEmptyWindowOrANegativeLimit() {
    #expect(throws: ReminderQueryError.horizonOutOfRange(0)) { try ReminderQuery(horizonDays: 0, limit: 1, device: .gmt) }
    #expect(throws: ReminderQueryError.horizonOutOfRange(32)) { try ReminderQuery(horizonDays: 32, limit: 1, device: .gmt) }
    #expect(throws: ReminderQueryError.negativeLimit(-1)) { try ReminderQuery(limit: -1, device: .gmt) }
  }
}
