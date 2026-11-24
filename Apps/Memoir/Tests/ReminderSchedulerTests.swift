import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

@MainActor
@Suite("ReminderScheduler", TestTimeLimit.standard)
struct ReminderSchedulerTests {
  private static let otherApp = "com.shadow.apps.memoir.other-request"

  @Test("should schedule the plan in the owner's words and remove only its own requests that left it")
  func schedulesThePlan() async throws {
    let world = try await ReminderWorld()
    let walk = try await world.quest("Walk")
    try await world.subscription("Music")
    let stale = Reminder.identifierPrefix + "stale"
    world.fake.foreign = [Self.otherApp]
    world.fake.pending[stale] = ReminderRequest(identifier: stale, title: "", body: "", fireAt: Date(), thread: "", userInfo: [:])

    world.start()
    defer { world.stop() }

    try await world.until("the week's reminders") { $0.questRequests(walk).count == 7 && $0.subscriptionRequests.count == 1 }
    #expect(world.fake.pending[stale] == nil)
    #expect(world.fake.foreign == [Self.otherApp], "another request of the app stays")
    let first = try #require(world.fake.questRequests(walk).min { $0.fireAt < $1.fireAt })
    #expect(first.title == "Walk")
    #expect(first.fireAt == TestClock.date(day: 0, minute: 465), "15 minutes before 08:00 in the account's zone")
    #expect(first.body == ReminderCopy.questBody(startMinute: 480, leadMinutes: 15, isRescheduled: false, locale: .current))
    #expect(first.userInfo == ["kind": "quest", "record": walk.uuidString.lowercased(), "date": TestClock.day0.isoString])
    let music = try #require(world.fake.subscriptionRequests.first)
    #expect(music.title == "Music")
    #expect(music.fireAt == TestClock.date(day: 2, minute: 360), "the start of the wake window the day before the charge")
    #expect(music.body.contains(try #require(ReminderCopy.amount(ReminderWorld.musicAmount, locale: .current))))
    #expect(world.fake.authorizationRequests == 0, "already allowed")
  }

  @Test("should withdraw an occurrence's request once it is completed, and every request of a deleted quest")
  func followsCompletions() async throws {
    let world = try await ReminderWorld()
    let walk = try await world.quest("Walk")
    let read = try await world.quest("Read", start: 1_200)
    world.start()
    defer { world.stop() }
    try await world.until("both quests' reminders") { $0.questRequests(walk).count == 7 && $0.questRequests(read).count == 7 }

    try await world.context.writer.issue(.questComplete(Occurrence(quest: walk, date: TestClock.day0)))

    try await world.until("today's walk to be withdrawn") { $0.questRequests(walk).count == 6 }
    #expect(!world.fake.questRequests(walk).contains { $0.userInfo["date"] == TestClock.day0.isoString })
    #expect(world.fake.questRequests(read).count == 7)

    try await world.context.writer.issue(.questDelete(QuestReference(questId: read)))

    try await world.until("the deleted quest's reminders to be withdrawn") { $0.questRequests(read).isEmpty }
    #expect(world.fake.questRequests(walk).count == 6)
  }

  @Test("should remove a shown reminder once its occurrence is settled, and leave the others shown")
  func removesSettledShownReminders() async throws {
    let world = try await ReminderWorld()
    let walk = try await world.quest("Walk")
    let read = try await world.quest("Read", start: 1_200)
    let music = try await world.subscription("Music")
    let shown = { (name: String) in Reminder.identifierPrefix + name }
    let info = { (kind: ReminderKind, record: UUID, day: Int) in ReminderCopy.userInfo(ReminderOccurrence(kind: kind, record: record, date: TestClock.day(day))) }
    world.fake.delivered = [
      shown("walk-today"): info(.quest, walk, 0), shown("walk-tomorrow"): info(.quest, walk, 1), shown("read-today"): info(.quest, read, 0),
      shown("music"): info(.subscription, music, 3), shown("unreadable"): ["kind": "quest", "record": walk.uuidString, "date": "today"],
      Self.otherApp: info(.quest, walk, 0),
    ]
    world.start()
    defer { world.stop() }
    try await world.until("the reminders") { $0.questRequests(walk).count == 7 && $0.questRequests(read).count == 7 }
    #expect(world.fake.delivered.count == 6, "nothing is settled yet")

    try await world.context.writer.issue(.questComplete(Occurrence(quest: walk, date: TestClock.day0)))
    try await world.until("today's shown walk to be removed") { $0.delivered[shown("walk-today")] == nil }
    #expect(Set(world.fake.delivered.keys) == [shown("walk-tomorrow"), shown("read-today"), shown("music"), shown("unreadable"), Self.otherApp])

    try await world.context.writer.issue(.questDelete(QuestReference(questId: read)))
    try await world.until("the deleted quest's shown reminder to be removed") { $0.delivered[shown("read-today")] == nil }

    try await world.context.writer.write { issuer, transaction in
      _ = try issuer.confirmCycle(CycleConfirmation(subscription: music, billingDate: TestClock.day(3)), in: &transaction)
    }
    try await world.until("the confirmed cycle's shown reminder to be removed") { $0.delivered[shown("music")] == nil }
    #expect(Set(world.fake.delivered.keys) == [shown("walk-tomorrow"), shown("unreadable"), Self.otherApp], "another request of the app stays shown")
  }

  @Test("should withdraw every request when the device setting is turned off, and schedule again when it is turned on")
  func followsTheDeviceSetting() async throws {
    let world = try await ReminderWorld()
    let walk = try await world.quest("Walk")
    world.fake.foreign = [Self.otherApp]
    world.start()
    defer { world.stop() }
    try await world.until("the reminders") { $0.questRequests(walk).count == 7 }

    world.scheduler.setOnThisDevice(false)

    try await world.until("every reminder to be withdrawn") { $0.pending.isEmpty }
    #expect(world.fake.foreign == [Self.otherApp])
    #expect(world.defaults.defaults.object(forKey: ReminderDeviceSetting.key) as? Bool == false)
    #expect(ReminderDeviceSetting(defaults: world.defaults.defaults, remindsByDefault: true).isOn == false, "the choice outlives the scheduler")

    world.scheduler.setOnThisDevice(true)

    try await world.until("the reminders to come back") { $0.questRequests(walk).count == 7 }
  }

  @Test("should stay quiet where reminders are off by default, without asking for permission")
  func staysQuietByDefault() async throws {
    let world = try await ReminderWorld(remindsByDefault: false)
    world.fake.status = .notDetermined
    let walk = try await world.quest("Walk")
    world.start()
    defer { world.stop() }

    try await Task.sleep(for: .milliseconds(300))
    #expect(!world.scheduler.isOnThisDevice)
    #expect(world.fake.pending.isEmpty && world.fake.authorizationRequests == 0)

    world.scheduler.setOnThisDevice(true)

    try await world.until("the reminders once allowed") { $0.questRequests(walk).count == 7 }
    #expect(world.fake.authorizationRequests == 1)
    #expect(world.scheduler.authorization == .allowed)
  }

  @Test("should ask for permission only once there is a reminder, schedule nothing when refused, and catch up once allowed in Settings")
  func asksForPermission() async throws {
    let world = try await ReminderWorld()
    world.fake.status = .notDetermined
    world.fake.grants = false
    world.start()
    defer { world.stop() }

    try await world.until("the empty plan's permission state") { _ in world.scheduler.authorization == .notDetermined }
    #expect(world.fake.authorizationRequests == 0, "no reminder, no prompt")

    let walk = try await world.quest("Walk")

    try await world.until("the refusal") { _ in world.scheduler.authorization == .denied }
    #expect(world.fake.authorizationRequests == 1)
    #expect(world.fake.pending.isEmpty)

    world.fake.status = .allowed
    world.center.post(name: ReminderWorld.activated, object: nil)

    try await world.until("the reminders after returning from Settings") { $0.questRequests(walk).count == 7 }
    #expect(world.fake.authorizationRequests == 1, "a decided permission is never asked again")
  }

  @Test("should keep subscription reminders and pause quest reminders after a replay halt")
  func pausesQuestsOnAHalt() async throws {
    let world = try await ReminderWorld()
    let walk = try await world.quest("Walk")
    try await world.subscription("Music")
    world.start()
    defer { world.stop() }
    try await world.until("the reminders") { $0.questRequests(walk).count == 7 && $0.subscriptionRequests.count == 1 }
    #expect(!world.scheduler.questsPaused)

    try await world.append(
      try MemoirCommand(
        id: UUID.v7(at: TestClock.date(day: 0, minute: 290)), body: .recoveryComplete(RecoveryCompletion()), instantMillis: TestClock.millis(day: 0, minute: 290),
        utcOffsetMinutes: 0, issuedOn: TestClock.day0, rulesetVersion: 3))

    try await world.until("the quest reminders to pause") { $0.questRequests(walk).isEmpty }
    #expect(world.fake.subscriptionRequests.count == 1)
    #expect(world.scheduler.questsPaused)
    world.stop()
    #expect(!world.scheduler.questsPaused, "a closed vault's notes go with it")
  }

  @Test("should keep at most its limit pending and report the rest as left out")
  func reportsOmitted() async throws {
    let world = try await ReminderWorld(limit: 3)
    let walk = try await world.quest("Walk")
    try await world.subscription("Music")
    world.start()
    defer { world.stop() }

    try await world.until("the capped plan") { _ in world.scheduler.omitted == 5 }
    #expect(world.fake.pending.count == 3)
    #expect(world.fake.questRequests(walk).map(\.fireAt).sorted() == [TestClock.date(day: 0, minute: 465), TestClock.date(day: 1, minute: 465)])
    #expect(world.fake.subscriptionRequests.count == 1, "the soonest three: day 0, day 1 and the subscription on day 2")
  }

  @Test("should plan again in the device's new zone when it changes before the account has a zone")
  func followsTheDeviceZone() async throws {
    let world = try await ReminderWorld(setsAccountZone: false)
    let walk = try await world.quest("Walk")
    world.start()
    defer { world.stop() }
    try await world.until("the reminders in UTC") { $0.questRequests(walk).contains { $0.fireAt == TestClock.date(day: 1, minute: 465) } }

    world.deviceZone.set(TestClock.berlin)
    world.center.post(name: ReminderWorld.zoneChanged, object: nil)

    try await world.until("the reminders in Berlin") { $0.questRequests(walk).contains { $0.fireAt == TestClock.date(day: 1, minute: 405) } }
    #expect(world.fake.questRequests(walk).allSatisfy { $0.fireAt != TestClock.date(day: 1, minute: 465) }, "the UTC requests are withdrawn")
  }

  @Test("should stop following a closed vault and leave its requests pending")
  func stopsWithTheVault() async throws {
    let world = try await ReminderWorld()
    let walk = try await world.quest("Walk")
    world.start()
    try await world.until("the reminders") { $0.questRequests(walk).count == 7 }

    world.scheduler.follow(nil)
    try await world.context.writer.issue(.questComplete(Occurrence(quest: walk, date: TestClock.day0)))
    world.center.post(name: ReminderWorld.activated, object: nil)
    try await Task.sleep(for: .milliseconds(300))

    #expect(world.fake.questRequests(walk).count == 7)
  }

  @Test("should finish the add under way and start none from a plan that has changed, then apply the new plan")
  func appliesOnlyTheLatestPlan() async throws {
    let world = try await ReminderWorld()
    let walk = try await world.quest("Walk")
    let read = try await world.quest("Read", start: 1_200)
    world.fake.parksNextAdd = true
    world.start()
    defer { world.stop() }
    try await world.until("the first add to park") { $0.isParked }

    try await world.context.writer.issue(.questDelete(QuestReference(questId: walk)))
    let scheduler = world.scheduler
    try await TestClock.until("the new plan to arrive") { scheduler.upcoming == 7 }
    world.fake.release()

    try await world.until("the new plan's requests") { $0.questRequests(read).count == 7 && $0.questRequests(walk).isEmpty }
    try await Task.sleep(for: .milliseconds(200))
    let plan = try await ReminderReads.plan(
      in: world.context.stores, query: try ReminderQuery(limit: ReminderScheduler.planLimit, device: TestClock.utc), now: world.clock.now())
    #expect(Set(world.fake.pending.keys) == plan.identifiers)
    #expect(world.fake.adds == 8, "the add under way and the new plan's seven; none of the deleted quest's after the plan changed")
  }

  @Test("should withdraw every pending and delivered reminder when the vault is deleted, and leave other requests")
  func withdrawsAll() async throws {
    let world = try await ReminderWorld(limit: 3)
    let walk = try await world.quest("Walk")
    let shown = Reminder.identifierPrefix + "shown"
    world.fake.foreign = [Self.otherApp]
    world.fake.delivered = [shown: [:], Self.otherApp: [:]]
    world.start()
    try await world.until("the reminders") { $0.questRequests(walk).count == 3 }
    #expect(world.scheduler.omitted == 4 && world.scheduler.upcoming == 3)

    world.scheduler.withdrawAll()

    try await world.until("every reminder to be withdrawn") { $0.pending.isEmpty && Set($0.delivered.keys) == [Self.otherApp] }
    #expect(world.fake.foreign == [Self.otherApp])
    #expect(world.scheduler.omitted == 0 && world.scheduler.upcoming == 0 && !world.scheduler.questsPaused)
    world.center.post(name: ReminderWorld.activated, object: nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(world.fake.pending.isEmpty, "nothing comes back until a vault is followed again")
  }
}

/// An in-memory vault at 05:00 UTC on `TestClock.day0`, a fake notification center and a scheduler following the vault.
@MainActor
final class ReminderWorld {
  static let zoneChanged = Notification.Name("ReminderSchedulerTests.zoneChanged")
  static let activated = Notification.Name("ReminderSchedulerTests.activated")
  static let musicAmount = MoneyAmount(amountMinor: 1_299, currency: CurrencyCode("EUR")!)

  let clock = TestClock(day: 0, minute: 300)
  let deviceZone = DeviceZone(TestClock.utc)
  let opened: MemoirOpenedVault
  let context: MemoirScreenContext
  let fake = FakeReminderNotifications()
  let defaults = ScratchDefaults()
  let center = NotificationCenter()
  let scheduler: ReminderScheduler

  init(remindsByDefault: Bool = true, limit: Int = ReminderScheduler.planLimit, setsAccountZone: Bool = true) async throws {
    let zone = deviceZone
    let memoir = MemoirClock(now: clock.now, deviceZone: { zone.value }, waitUntil: HeldWaits().wait)
    opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: memoir)
    context = MemoirScreenContext(opened)
    if setsAccountZone { try await context.writer.issue(try TestQuests.zone("UTC")) }
    scheduler = ReminderScheduler(
      notifications: fake, setting: ReminderDeviceSetting(defaults: defaults.defaults, remindsByDefault: remindsByDefault), limit: limit, center: center,
      restartOn: [Self.zoneChanged, Self.activated])
  }

  func start() {
    scheduler.follow(opened)
  }

  func stop() {
    scheduler.stop()
  }

  func quest(_ name: String, start: Int = 480, lead: Int = 15) async throws -> UUID {
    let id = UUID()
    let schedule = try QuestSchedule(
      strictness: .routine, startTimeMinutes: start, durationMinutes: 30, statAffinity: .body, recurrence: try RecurrenceRule(frequency: .daily, startDate: TestClock.day0))
    try await context.writer.issue(
      .questCreate(QuestCreation(questId: id, schedule: schedule)), creating: QuestRecord(id: id, name: name, reminderEnabled: true, reminderLeadMinutes: lead))
    return id
  }

  @discardableResult
  func subscription(_ name: String) async throws -> UUID {
    let record = SubscriptionRecord(
      id: UUID(), name: name, amountMinor: Self.musicAmount.amountMinor, currency: Self.musicAmount.currency, frequency: .known(.monthly), billingDay: 5,
      anchorOn: TestClock.day(3), category: try #require(CategoryKey("subscriptions")), reminderEnabled: true, reminderLead: .known(.oneDay))
    _ = try await context.stores.main.write { transaction in try record.create(in: &transaction) }
    return record.id
  }

  func append(_ command: MemoirCommand) async throws {
    _ = try await context.stores.main.write { transaction in try command.append(in: &transaction) }
  }

  func until(_ what: String, _ condition: @escaping (FakeReminderNotifications) -> Bool) async throws {
    let fake = fake
    try await TestClock.until(what) { condition(fake) }
  }
}

nonisolated final class DeviceZone: Sendable {
  private let zone: Mutex<TimeZone>

  init(_ zone: TimeZone) {
    self.zone = Mutex(zone)
  }

  var value: TimeZone { zone.withLock { $0 } }

  func set(_ zone: TimeZone) {
    self.zone.withLock { $0 = zone }
  }
}

@MainActor
final class FakeReminderNotifications: ReminderNotifications {
  var pending: [String: ReminderRequest] = [:]
  var foreign: Set<String> = []
  var status = ReminderAuthorization.allowed
  /// Shown notifications by identifier, with their requests' `userInfo`.
  var delivered: [String: [String: String]] = [:]
  var grants = true
  var parksNextAdd = false
  private(set) var authorizationRequests = 0
  private(set) var adds = 0
  private var parked: CheckedContinuation<Void, Never>?

  var isParked: Bool { parked != nil }

  func release() {
    parked?.resume()
    parked = nil
  }

  var questRequests: [ReminderRequest] { pending.values.filter { $0.userInfo["kind"] == ReminderKind.quest.rawValue } }
  var subscriptionRequests: [ReminderRequest] { pending.values.filter { $0.userInfo["kind"] == ReminderKind.subscription.rawValue } }

  func questRequests(_ quest: UUID) -> [ReminderRequest] {
    questRequests.filter { $0.userInfo["record"] == quest.uuidString.lowercased() }
  }

  func pendingIdentifiers() async -> Set<String> {
    Set(pending.keys).union(foreign)
  }

  func add(_ request: ReminderRequest) async throws(ReminderNotificationError) {
    if parksNextAdd {
      parksNextAdd = false
      await withCheckedContinuation { parked = $0 }
    }
    adds += 1
    pending[request.identifier] = request
  }

  func remove(_ identifiers: [String]) {
    for identifier in identifiers {
      pending[identifier] = nil
      foreign.remove(identifier)
    }
  }

  func delivered() async -> [DeliveredReminder] {
    delivered.map { DeliveredReminder(identifier: $0.key, userInfo: $0.value) }
  }

  func removeDelivered(_ identifiers: [String]) {
    for identifier in identifiers { delivered[identifier] = nil }
  }

  func authorization() async -> ReminderAuthorization {
    status
  }

  func requestAuthorization() async throws(ReminderNotificationError) -> Bool {
    authorizationRequests += 1
    status = grants ? .allowed : .denied
    return grants
  }
}
