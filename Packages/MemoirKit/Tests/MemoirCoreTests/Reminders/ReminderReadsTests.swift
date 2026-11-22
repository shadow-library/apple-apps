import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import MemoirCore

@Suite("Memoir reminder reads", TestTimeLimit.quick)
struct ReminderReadsTests {
  private typealias Device = ReadsDevice

  private static let subscription = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000e101")

  private static func date(_ day: LocalDate, minute: Int) -> Date {
    Date(timeIntervalSince1970: Double(Device.stamp(day, minute: minute).instantMillis) / 1000)
  }

  private static func millis(_ day: LocalDate, minute: Int) -> Int64 {
    Device.stamp(day, minute: minute).instantMillis
  }

  private static func query(days: Int = 7) throws -> ReminderQuery {
    try ReminderQuery(horizonDays: days, limit: ReminderQuery.systemPendingLimit, device: .gmt)
  }

  private static func open() throws -> (Device, MemoirStores) {
    nonisolated(unsafe) var opened: MemoirStores?
    let device = try Device { reconciler in
      let stores = try MemoirStores.openInMemory(projection: reconciler)
      opened = stores
      return stores.main
    }
    return (device, try #require(opened))
  }

  private static func remind(_ quest: UUID, lead: Int, in device: Device) async throws {
    _ = try await device.store.write { transaction in
      try QuestRecord.edit(id: quest, in: &transaction) { record in
        record.reminderEnabled = true
        record.reminderLeadMinutes = lead
      }
    }
  }

  /// The routine at 08:00 with a 15-minute lead and the goal without a time, both reminded; the anchor and the optional quest are not.
  private static func seeded() async throws -> (Device, MemoirStores) {
    let (device, stores) = try Self.open()
    try await device.createStandardQuests()
    try await remind(Device.routine, lead: 15, in: device)
    try await remind(Device.goal, lead: 30, in: device)
    try await device.walk(to: Device.day(0))
    return (device, stores)
  }

  private static func dates(of quest: UUID, in plan: ReminderPlan) -> [LocalDate] {
    plan.reminders.compactMap { reminder in
      guard case .quest(let content) = reminder.content, content.quest == quest else { return nil }
      return content.date
    }
  }

  @Test func shouldPlanTheRemindedQuestsFromTheProjection() async throws {
    let (_, stores) = try await Self.seeded()
    let plan = try await ReminderReads.plan(in: stores, query: try Self.query(days: 2), now: Self.date(Device.day(0), minute: 300))
    #expect(
      plan.reminders.map(\.fireAtMillis) == [
        Self.millis(Device.day(0), minute: 360), Self.millis(Device.day(0), minute: 465), Self.millis(Device.day(1), minute: 360),
        Self.millis(Device.day(1), minute: 465),
      ], "the goal at the 06:00 start of the standard wake window, the routine at 07:45, in the device's zone before the account has one")
    #expect(Set(plan.reminders.map(\.content.kind)) == [.quest] && plan.halt == nil)
    #expect(Self.dates(of: Device.anchor, in: plan).isEmpty && Self.dates(of: Device.optional, in: plan).isEmpty)
  }

  @Test func shouldDropAnOccurrenceOnceItIsCompletedAndEveryOccurrenceOnceTheQuestIsDeleted() async throws {
    let (device, stores) = try await Self.seeded()
    let now = Self.date(Device.day(0), minute: 300)
    try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(0))), on: Device.day(0), minute: 310)
    let completed = try await ReminderReads.plan(in: stores, query: try Self.query(days: 2), now: now)
    #expect(Self.dates(of: Device.routine, in: completed) == [Device.day(1)])
    try await device.issue(.questDelete(QuestReference(questId: Device.goal)), on: Device.day(0), minute: 320)
    let deleted = try await ReminderReads.plan(in: stores, query: try Self.query(days: 2), now: now)
    #expect(Self.dates(of: Device.goal, in: deleted).isEmpty)
    _ = try await device.store.write { transaction in try QuestRecord.edit(id: Device.routine, in: &transaction) { $0.reminderEnabled = false } }
    #expect(try await ReminderReads.plan(in: stores, query: try Self.query(days: 2), now: now).reminders.isEmpty)
  }

  @Test func shouldSettleTheRemindedOccurrencesCompletedOrDeletedTodayAndYesterday() async throws {
    let (device, stores) = try await Self.seeded()
    let today = Self.date(Device.day(0), minute: 600)
    #expect(try await ReminderReads.plan(in: stores, query: try Self.query(), now: today).settled.isEmpty)

    try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(0))), on: Device.day(0), minute: 500)
    try await device.issue(.questComplete(Occurrence(quest: Device.anchor, date: Device.day(0))), on: Device.day(0), minute: 510)
    try await device.issue(.questDelete(QuestReference(questId: Device.goal)), on: Device.day(0), minute: 520)
    let plan = try await ReminderReads.plan(in: stores, query: try Self.query(), now: today)
    #expect(
      plan.settled == [
        ReminderOccurrence(kind: .quest, record: Device.routine, date: Device.day(0)), ReminderOccurrence(kind: .quest, record: Device.goal, date: Device.day(0)),
      ], "the anchor asks for no reminder; the goal began on day 0")

    try await device.walk(to: Device.day(2))
    let later = try await ReminderReads.plan(in: stores, query: try Self.query(), now: Self.date(Device.day(2), minute: 600))
    #expect(
      later.settled == [ReminderOccurrence(kind: .quest, record: Device.goal, date: Device.day(1)), ReminderOccurrence(kind: .quest, record: Device.goal, date: Device.day(2))])
  }

  @Test func shouldGiveTheSameIdentifiersOnEveryDeviceAndAfterAnotherReplay() async throws {
    let (first, firstStores) = try await Self.seeded()
    let (_, secondStores) = try await Self.seeded()
    let now = Self.date(Device.day(0), minute: 300)
    let plan = try await ReminderReads.plan(in: firstStores, query: try Self.query(), now: now)
    #expect(plan.reminders.count == 14)
    #expect(try await ReminderReads.plan(in: secondStores, query: try Self.query(), now: now).reminders == plan.reminders)
    try await first.walk(to: Device.day(0), minute: 200)
    #expect(try await ReminderReads.plan(in: firstStores, query: try Self.query(), now: now).identifiers == plan.identifiers)
  }

  @Test func shouldRemindAnOpenSubscriptionCycleUntilItIsConfirmedAndNeverAnInactiveOrRemovedOne() async throws {
    let (device, stores) = try Self.open()
    let wake = try #require(ScheduleWindow(start: 420, end: 1_380))
    let eur = try #require(CurrencyCode("EUR"))
    let music = SubscriptionRecord(
      id: Self.subscription, name: "Music", amountMinor: 1_299, currency: eur, frequency: .known(.monthly), billingDay: 5, anchorOn: Device.day(3),
      category: MoneyReadsFixture.category("subs"), reminderEnabled: true, reminderLead: .known(.oneDay))
    let paused = SubscriptionRecord(
      id: MoneyReadsFixture.id(2), name: "Paused", amountMinor: 500, currency: eur, frequency: .known(.monthly), billingDay: 5, anchorOn: Device.day(3),
      category: MoneyReadsFixture.category("subs"), reminderEnabled: true, reminderLead: .known(.oneDay), active: false)
    let unknown = SubscriptionRecord(
      id: MoneyReadsFixture.id(3), name: "Newer", amountMinor: 500, currency: eur, frequency: .known(.monthly), billingDay: 5, anchorOn: Device.day(3),
      category: MoneyReadsFixture.category("subs"), reminderEnabled: true, reminderLead: .unknown("2_weeks"))
    let removed = SubscriptionRecord(
      id: MoneyReadsFixture.id(4), name: "Gone", amountMinor: 500, currency: eur, frequency: .known(.monthly), billingDay: 5, anchorOn: Device.day(3),
      category: MoneyReadsFixture.category("subs"), reminderEnabled: true, reminderLead: .known(.oneDay))
    try await MoneyReadsFixture.seed(
      stores.main, [AccountSettingsRecord(defaultCurrency: eur, enabledCurrencies: [eur], schedule: wake), music, paused, unknown, removed])
    _ = try await stores.main.write { transaction in try SubscriptionRecord.remove(removed.ref, in: &transaction) }
    let now = Self.date(Device.day(0), minute: 600)

    let plan = try await ReminderReads.plan(in: stores, query: try Self.query(), now: now)
    #expect(plan.reminders.map(\.fireAtMillis) == [Self.millis(Device.day(2), minute: 420)], "07:00 the day before the charge")
    #expect(
      plan.reminders.first?.content
        == .subscription(
          SubscriptionReminder(
            subscription: Self.subscription, name: "Music", dueOn: Device.day(3), amount: MoneyAmount(amountMinor: 1_299, currency: eur), lead: .oneDay)))

    try await device.issue(.subscriptionConfirmCycle(CycleConfirmation(subscription: Self.subscription, billingDate: Device.day(3))), on: Device.day(0))
    let confirmed = try await ReminderReads.plan(in: stores, query: try Self.query(), now: now)
    #expect(confirmed.reminders.isEmpty, "the next cycle is a month away")
    #expect(confirmed.settled == [ReminderOccurrence(kind: .subscription, record: Self.subscription, date: Device.day(3))])
    #expect(try await ReminderReads.plan(in: stores, query: try Self.query(), now: Self.date(Device.day(2), minute: 600)).settled.isEmpty, "confirmed two days ago")
  }

  @Test func shouldKeepQuestRemindersWhenTheSettingsAndASubscriptionCannotBeRead() async throws {
    let (_, stores) = try await Self.seeded()
    _ = try await stores.main.write { transaction in
      try transaction.set(MemoirKey.accountSettings.ref, ["natural_key": MemoirKey.accountSettings.stored, "default_currency": 7])
      try transaction.set(SubscriptionRecord.ref(Self.subscription), ["name": 7, "reminder_enabled": true])
    }
    #expect(try await stores.main.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry } == nil)
    #expect(try await stores.main.read { transaction in try SubscriptionRecord.listing(in: transaction).unreadable } == 1)
    let plan = try await ReminderReads.plan(in: stores, query: try Self.query(days: 1), now: Self.date(Device.day(0), minute: 300))
    #expect(plan.reminders.map(\.fireAtMillis) == [Self.millis(Device.day(0), minute: 360), Self.millis(Device.day(0), minute: 465)], "the goal at the standard 06:00")
  }

  @Test func shouldHoldAStoredLeadWithinTheReferenceRange() async throws {
    let (device, stores) = try Self.open()
    try await device.createStandardQuests()
    try await Self.remind(Device.routine, lead: -5, in: device)
    try await Self.remind(Device.anchor, lead: .max, in: device)
    try await device.walk(to: Device.day(0))
    let plan = try await ReminderReads.plan(in: stores, query: try Self.query(days: 31), now: Self.date(Device.day(0), minute: 300))
    let leads = Dictionary(
      grouping: plan.reminders.compactMap { reminder -> QuestReminder? in
        guard case .quest(let content) = reminder.content else { return nil }
        return content
      }, by: \.quest
    ).mapValues { Set($0.map(\.leadMinutes)) }
    #expect(leads[Device.routine] == [0] && leads[Device.anchor] == [Int(Int16.max)])
    let anchor = try #require(
      plan.reminders.first { reminder in
        guard case .quest(let content) = reminder.content else { return false }
        return content.quest == Device.anchor
      })
    guard case .quest(let content) = anchor.content else { return }
    #expect(anchor.fireAtMillis == Self.millis(content.date, minute: 420) - Int64(Int16.max) * 60_000)
  }

  @Test func shouldStopWaitingWhenTheObservationIsCancelled() async throws {
    let (_, stores) = try await Self.seeded()
    let cancelled = Mutex(false)
    let plans = ReminderReads.observePlan(
      in: stores, query: try Self.query(), now: { Self.date(Device.day(0), minute: 300) },
      waitUntil: { _ in
        do {
          try await Task.sleep(for: .seconds(3_600))
        } catch {
          cancelled.withLock { $0 = true }
          throw error
        }
      })
    let (started, signal) = AsyncStream<Void>.makeStream()
    let consumer = Task {
      var iterator = plans.makeAsyncIterator()
      _ = try await iterator.next()
      signal.yield()
      _ = try await iterator.next()
    }
    var startedIterator = started.makeAsyncIterator()
    _ = await startedIterator.next()
    consumer.cancel()
    for _ in 0..<400 where !cancelled.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(cancelled.withLock { $0 }, "the pending wait for the next fire is cancelled with the stream")
  }

  @Test func shouldReEmitAfterACompletionAndWhenAReminderFires() async throws {
    let (device, stores) = try await Self.seeded()
    let now = Mutex(Self.date(Device.day(0), minute: 300))
    let waits = Mutex<[Date]>([])
    let armed = Mutex(false)
    let plans = ReminderReads.observePlan(
      in: stores, query: try Self.query(days: 1), now: { now.withLock { $0 } },
      waitUntil: { until in
        waits.withLock { $0.append(until) }
        while !armed.withLock({ armed in
          defer { armed = false }
          return armed
        }) { try await Task.sleep(for: .milliseconds(5)) }
        now.withLock { $0 = until }
      })
    var iterator = plans.makeAsyncIterator()

    let first = try #require(try await iterator.next())
    #expect(Self.dates(of: Device.routine, in: first) == [Device.day(0)] && Self.dates(of: Device.goal, in: first) == [Device.day(0)])
    #expect(first.changesAt == Self.date(Device.day(0), minute: 360))

    try await device.issue(.questComplete(Occurrence(quest: Device.routine, date: Device.day(0))), on: Device.day(0), minute: 310)
    let completed = try #require(try await iterator.next())
    #expect(Self.dates(of: Device.routine, in: completed).isEmpty && Self.dates(of: Device.goal, in: completed) == [Device.day(0)])

    armed.withLock { $0 = true }
    let fired = try #require(try await iterator.next())
    #expect(Self.dates(of: Device.goal, in: fired) == [Device.day(1)] && Self.dates(of: Device.routine, in: fired).isEmpty, "the window moved to the fire instant")
    #expect(fired.changesAt == Self.date(Device.day(0), minute: 465), "when the routine's 07:45 the next day comes within the window")
    #expect(waits.withLock { $0.first } == Self.date(Device.day(0), minute: 360))
  }

  @Test func shouldKeepEveryHealthValueOutOfThePlan() async throws {
    let (device, stores) = try await Self.seeded()
    let issuer = CommandIssuer(clock: IssueClock(timeZone: .gmt), wallClock: { Self.date(Device.day(0), minute: 400) })
    _ = try await QuickLogWriter(stores: stores, issuer: CommandIssuerSource { _ in issuer }).saveWeight(HealthFixture.decimal("81.2345"), on: Device.day(0))
    try await device.walk(to: Device.day(0), minute: 401)
    let sources = try await ReminderReads.sources(in: stores)
    let plan = ReminderPlan.make(sources, query: try Self.query(), now: Self.date(Device.day(0), minute: 300))
    #expect(!plan.reminders.isEmpty)
    for dump in [String(reflecting: sources), String(reflecting: plan)] {
      #expect(!dump.contains("81.2345") && !dump.contains("81,2345"))
    }
  }
}
