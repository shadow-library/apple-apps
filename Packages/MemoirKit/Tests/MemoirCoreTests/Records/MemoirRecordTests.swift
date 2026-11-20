import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir records", TestTimeLimit.quick)
struct MemoirRecordTests {
  private static let id = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000c1")

  private func roundTrip<Record: MemoirRecord>(_ record: Record, in store: VaultStore) async throws {
    _ = try await store.write { transaction in try record.create(in: &transaction) }
    let read = try await store.read { transaction in try Record.read(record.ref, in: transaction) }
    #expect(read == .readable(MemoirEntry(record: record, isRemoved: false)), "\(Record.kind.rawValue) did not round-trip")
  }

  private func expense(rate: ExpenseRate? = nil) throws -> ExpenseRecord {
    ExpenseRecord(
      id: Self.id, amountMinor: 1_250, currency: try MemoirStoreFixture.currency("JPY"), occurredOn: try MemoirStoreFixture.date("2026-11-20"),
      category: try MemoirStoreFixture.category("groceries"), merchant: "Corner shop", rate: rate, loggedAtMillis: 1_763_600_000_000)
  }

  @Test func shouldRoundTripEveryRecordKindThroughTheStoreOfItsClass() async throws {
    let main = try MemoirStore.openInMemory(.main)
    let activity = try MemoirStore.openInMemory(.activity)
    let restricted = try MemoirStore.openInMemory(.restricted)
    let day = try MemoirStoreFixture.date("2026-11-20")
    let eur = try MemoirStoreFixture.currency("EUR")
    let groceries = try MemoirStoreFixture.category("groceries")
    try await roundTrip(QuestRecord(id: MemoirStoreFixture.quest, name: "Morning run", notes: "Loop the park", reminderEnabled: true, reminderLeadMinutes: 15), in: main)
    try await roundTrip(JournalEntryRecord(id: Self.id, date: day, text: "A long day.", mood: 3, tags: ["work"], loggedAtMillis: 5), in: main)
    try await roundTrip(MealRecord(id: Self.id, date: day, name: "Ramen", calories: 640, mealType: .known(.ateOut), loggedAtMillis: 5), in: main)
    try await roundTrip(MealPresetRecord(id: Self.id, name: "Oats", calories: 300, mealType: .unknown("brunch")), in: main)
    try await roundTrip(SideQuestRecord(id: Self.id, date: day, name: "Fixed the tap", loggedAtMillis: 5), in: main)
    try await roundTrip(try expense(rate: ExpenseRate(rate: try MemoirStoreFixture.decimal("0.0061"), date: day, quote: eur)), in: main)
    try await roundTrip(
      SubscriptionRecord(
        id: Self.id, name: "Music", amountMinor: 999, currency: eur, frequency: .known(.monthly), billingDay: 3, anchorOn: day, category: groceries,
        reminderLead: .known(.oneWeek)), in: main)
    try await roundTrip(ExpenseCategoryRecord(key: groceries, label: "Groceries"), in: main)
    try await roundTrip(ReceiptRecord(id: Self.id, blob: try #require(BlobName(String(repeating: "ab", count: 32))), contentType: "image/jpeg", byteCount: 2_048), in: main)
    try await roundTrip(FxRateRecord(base: try MemoirStoreFixture.currency("JPY"), quote: eur, date: day, rate: try MemoirStoreFixture.decimal("0.0061")), in: main)
    try await roundTrip(
      AccountSettingsRecord(
        defaultCurrency: eur, enabledCurrencies: [eur], monthlyBudget: MoneyAmount(amountMinor: 150_000, currency: eur),
        schedule: try #require(ScheduleWindow(start: 420, end: 60)), weekStart: 0), in: main)
    try await roundTrip(MetricRecord<GeneralMetric>(id: MetricID(recordUUID: Self.id), name: "Pages read", valueType: .known(.count), direction: .known(.higher)), in: main)
    try await roundTrip(
      MetricDayRecord<GeneralMetric>(metric: MetricID(recordUUID: Self.id), date: day, value: try MemoirStoreFixture.decimal("12"), source: .known(.manual)), in: main)
    try await roundTrip(MetricRecord<ActivityMetric>(id: MetricID(recordUUID: Self.id), name: "Steps", valueType: .known(.count), direction: .known(.higher)), in: activity)
    try await roundTrip(
      MetricDayRecord<ActivityMetric>(metric: MetricID(recordUUID: Self.id), date: day, value: try MemoirStoreFixture.decimal("8042"), source: .known(.health)), in: activity)
    try await roundTrip(
      MetricRecord<HealthMetric>(id: MetricID(recordUUID: Self.id), name: "Resting heart rate", unit: "bpm", valueType: .known(.number), direction: .known(.lower)), in: restricted)
    try await roundTrip(
      MetricDayRecord<HealthMetric>(metric: MetricID(recordUUID: Self.id), date: day, value: try MemoirStoreFixture.decimal("58"), source: .known(.health)), in: restricted)
    try await roundTrip(WeightRecord(date: day, kilograms: try MemoirStoreFixture.decimal("72.45"), loggedAtMillis: 5), in: restricted)
  }

  @Test func shouldWriteOnlyTheMembersAnEditChanged() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let quest = QuestRecord(id: MemoirStoreFixture.quest, name: "Run", notes: "Slowly")
    _ = try await store.write { transaction in try quest.create(in: &transaction) }
    let changes = try await store.write { transaction in
      try QuestRecord.edit(id: quest.id, in: &transaction) { quest in
        quest.name = "Run far"
        quest.notes = nil
      }
    }
    #expect(changes.count == 1)
    #expect(changes.first.map { Set($0.fields.keys) } == ["name", "notes"])
    #expect(changes.first?.fields["notes"] == .null)
    let read = try await store.read { transaction in try QuestRecord.read(id: quest.id, in: transaction) }
    #expect(read.entry?.record == QuestRecord(id: quest.id, name: "Run far"))
    let unchanged = try await store.write { transaction in try QuestRecord.edit(id: quest.id, in: &transaction) { $0.name = "Run far" } }
    #expect(unchanged.isEmpty)
  }

  @Test func shouldRefuseEditingARecordThatIsNotThere() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let ref = QuestRecord.ref(MemoirStoreFixture.quest)
    await #expect(throws: StoreError.self) { try await store.write { transaction in try QuestRecord.edit(ref, in: &transaction) { $0.name = "Run" } } }
    let journal = JournalEntryRecord.ref(Self.id)
    await #expect(throws: StoreError.self) { try await store.write { transaction in try JournalEntryRecord.remove(journal, in: &transaction) } }
    await #expect(throws: StoreError.self) { try await store.write { transaction in try JournalEntryRecord.restore(journal, in: &transaction) } }
    #expect(try await store.pendingChanges(limit: 10).isEmpty)
  }

  @Test func shouldFillAnAbsentFirstWriterFieldOnceAndNeverChangeIt() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let expense = try expense()
    _ = try await store.write { transaction in try expense.create(in: &transaction) }
    let rate = ExpenseRate(rate: try MemoirStoreFixture.decimal("0.0061"), date: expense.occurredOn, quote: try MemoirStoreFixture.currency("EUR"))
    _ = try await store.write { transaction in try ExpenseRecord.edit(id: expense.id, in: &transaction) { $0.rate = rate } }
    let usd = try MemoirStoreFixture.currency("USD")
    let otherRate = ExpenseRate(rate: try MemoirStoreFixture.decimal("0.0062"), date: expense.occurredOn, quote: rate.quote)
    let refusals: [(field: String, change: @Sendable (inout ExpenseRecord) -> Void)] = [
      ("currency", { $0.currency = usd }), ("rate", { $0.rate = otherRate }), ("rate", { $0.rate = nil }), ("logged_at_millis", { $0.loggedAtMillis += 1 }),
    ]
    for (field, change) in refusals {
      let outcome = try await store.write { transaction -> String? in
        do throws(MemoirRecordError) {
          try ExpenseRecord.edit(id: expense.id, in: &transaction, change)
          return nil
        } catch {
          guard case .firstWriterField(_, let refused) = error else { return "unexpected \(error)" }
          return refused
        }
      }
      #expect(outcome == field)
    }
    let read = try await store.read { transaction in try ExpenseRecord.read(id: expense.id, in: transaction) }
    #expect(read.entry?.record.rate == rate)
    #expect(read.entry?.record.currency == expense.currency)
  }

  @Test func shouldRemoveAndRestoreARecord() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let meal = MealRecord(id: Self.id, date: try MemoirStoreFixture.date("2026-11-20"), name: "Soup", calories: 200, mealType: .known(.cooked), loggedAtMillis: 1)
    _ = try await store.write { transaction in try meal.create(in: &transaction) }
    _ = try await store.write { transaction in try MealRecord.remove(meal.ref, in: &transaction) }
    #expect(try await store.read { transaction in try MealRecord.read(meal.ref, in: transaction) }.entry?.isRemoved == true)
    _ = try await store.write { transaction in try MealRecord.edit(meal.ref, in: &transaction) { $0.note = "Leek" } }
    let restore = try await store.write { transaction in try MealRecord.restore(meal.ref, in: &transaction) }
    #expect(restore.fields.keys.sorted() == ["removed"])
    let listing = try await store.read { transaction in try MealRecord.listing(in: transaction) }
    var edited = meal
    edited.note = "Leek"
    #expect(listing.entries == [MemoirEntry(record: edited, isRemoved: false)])
    #expect(listing.unreadable == 0)
  }

  @Test func shouldKeepBothJournalTextsWhenTwoDevicesEditTheSameEntry() async throws {
    let clock = MemoirTestClock()
    let first = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let second = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let entry = JournalEntryRecord(id: Self.id, date: try MemoirStoreFixture.date("2026-11-20"), text: "Draft", loggedAtMillis: 1)
    _ = try await first.write { transaction in try entry.create(in: &transaction) }
    try await MemoirStoreFixture.exchange(first, second)
    clock.advance()
    let edit = try await first.write { transaction in try JournalEntryRecord.edit(id: entry.id, in: &transaction) { $0.text = "Written on the phone" } }
    #expect(edit.map(\.kind) == [.revise])
    clock.advance()
    _ = try await second.write { transaction in try JournalEntryRecord.edit(id: entry.id, in: &transaction) { $0.text = "Written on the Mac" } }
    try await MemoirStoreFixture.exchange(first, second)
    for store in [first, second] {
      let read = try await store.read { transaction in try JournalEntryRecord.read(id: entry.id, in: transaction) }
      #expect(read.entry?.record.text == "Written on the Mac")
      guard case .revisioned(let document)? = try await store.read({ transaction in try transaction.state(of: entry.ref) }) else {
        throw MemoirFixtureError(description: "the journal entry is not revisioned")
      }
      let texts = Set(document.revisions.values.compactMap { $0.body.objectValue?["text"]?.stringValue })
      #expect(texts == ["Draft", "Written on the phone", "Written on the Mac"])
    }
  }

  @Test func shouldKeepTheFirstRateEitherDeviceRecorded() async throws {
    let clock = MemoirTestClock()
    let first = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let second = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let date = try MemoirStoreFixture.date("2026-11-20")
    let jpy = try MemoirStoreFixture.currency("JPY")
    let eur = try MemoirStoreFixture.currency("EUR")
    _ = try await second.write { transaction in try FxRateRecord(base: jpy, quote: eur, date: date, rate: try MemoirStoreFixture.decimal("0.0061")).create(in: &transaction) }
    clock.advance()
    _ = try await first.write { transaction in try FxRateRecord(base: jpy, quote: eur, date: date, rate: try MemoirStoreFixture.decimal("0.0062")).create(in: &transaction) }
    try await MemoirStoreFixture.exchange(first, second)
    for store in [first, second] {
      let read = try await store.read { transaction in try FxRateRecord.read(key: .fxRate(base: jpy, quote: eur, date: date), in: transaction) }
      #expect(read.entry?.record.rate == (try MemoirStoreFixture.decimal("0.0061")))
    }
  }

  @Test func shouldCountARecordWithAMalformedFieldAsUnreadable() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let ref = QuestRecord.ref(MemoirStoreFixture.quest)
    _ = try await store.write { transaction in try transaction.set(ref, ["name": 7, "reminder_enabled": false, "reminder_lead_minutes": 0]) }
    let read = try await store.read { transaction in try QuestRecord.read(ref, in: transaction) }
    #expect(read == .unreadable(.invalid(field: "name")))
    #expect(try await store.read { transaction in try QuestRecord.listing(in: transaction) }.unreadable == 1)
  }

  @Test func shouldLeaveQuestDeletionToCommands() async throws {
    #expect(MemoirSchema.mainRegistry[MemoirKind.quest.entityKind]?.rule(forField: "removed") == nil)
    let store = try MemoirStore.openInMemory(.main)
    let quest = QuestRecord(id: MemoirStoreFixture.quest, name: "Run")
    let created = try await store.write { transaction in try quest.create(in: &transaction) }
    #expect(created.first.map { $0.fields.keys.sorted() } == ["name", "reminder_enabled", "reminder_lead_minutes"])
    await #expect(throws: StoreError.self) { try await store.write { transaction in try transaction.set(quest.ref, ["removed": true]) } }
  }

  @Test func shouldKeepTheScheduleWindowAValidPair() async throws {
    #expect(ScheduleWindow.standard.start == 360 && ScheduleWindow.standard.end == 1380)
    for (start, end) in [(360, 1380), (420, 60), (540, 0), (300, 1260)] { #expect(ScheduleWindow(start: start, end: end) != nil, "\(start)-\(end)") }
    for (start, end) in [(360, 300), (360, 900), (0, 0), (-1, 1200), (360, 1440), (1200, 300)] {
      #expect(ScheduleWindow(start: start, end: end) == nil, "\(start)-\(end)")
    }
    let store = try MemoirStore.openInMemory(.main)
    let ref = MemoirKey.accountSettings.ref
    let fields: [String: JSONValue] = [
      "natural_key": MemoirKey.accountSettings.stored, "default_currency": "EUR", "enabled_currencies": ["EUR"], "schedule": ["start": 360, "end": 300], "week_start": 1,
    ]
    _ = try await store.write { transaction in try transaction.set(ref, fields) }
    #expect(try await store.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction) } == .unreadable(.invalid(field: "schedule")))
  }

  @Test func shouldKeyAMetricDayByTheUUIDInsideItsClassTypedID() throws {
    let id = MetricID<HealthMetric>(recordUUID: MemoirStoreFixture.metric)
    let day = MetricDayRecord<HealthMetric>(metric: id, date: try MemoirStoreFixture.date("2026-11-20"), value: try MemoirStoreFixture.decimal("58"), source: .known(.health))
    #expect(day.key == .metricDay(.health, metric: MemoirStoreFixture.metric, date: day.date))
    #expect(id.stored == MemoirStoreFixture.metric.stored)
    #expect(MetricRecord<HealthMetric>.ref(id).key == EntityKey(uuid: MemoirStoreFixture.metric))
    #expect(MetricRecord<HealthMetric>.kind == .healthMetric && MetricDayRecord<HealthMetric>.kind == .healthMetricDay)
  }

  @Test func shouldAcceptOnlyCanonicalValueSpellings() {
    for text in ["0", "12", "-3", "0.5", "-0.25", "72.45", "1000000"] { #expect(DecimalText(text)?.text == text) }
    for text in ["", "-0", "+1", "01", "1.", ".5", "1.50", "0.0", "1e5", "1,5", " 1", String(repeating: "1", count: 41)] { #expect(DecimalText(text) == nil, "\(text)") }
    for code in ["EUR", "JPY"] { #expect(CurrencyCode(code)?.code == code) }
    for code in ["eur", "EU", "EURO", "E1R"] { #expect(CurrencyCode(code) == nil) }
    for key in ["groceries", "eating_out", "a1"] { #expect(CategoryKey(key)?.key == key) }
    for key in ["", "Groceries", "eating-out", String(repeating: "a", count: 33)] { #expect(CategoryKey(key) == nil) }
    #expect(BlobName(String(repeating: "0f", count: 32)) != nil)
    for name in [String(repeating: "0F", count: 32), String(repeating: "0f", count: 31), String(repeating: "g", count: 64)] { #expect(BlobName(name) == nil) }
  }
}
