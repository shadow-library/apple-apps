import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import Testing

@testable import MemoirCore

@Suite("Money and module records", TestTimeLimit.quick)
struct MoneyRecordTests {
  private static let id = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000d1")
  private static let budget = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000d2")
  private static let goal = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000d3")
  private static let command = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000d4")

  private func roundTrip<Record: MemoirRecord>(_ record: Record, in store: VaultStore) async throws {
    _ = try await store.write { transaction in try record.create(in: &transaction) }
    let read = try await store.read { transaction in try Record.read(record.ref, in: transaction) }
    #expect(read == .readable(MemoirEntry(record: record, isRemoved: false)), "\(Record.kind.rawValue) did not round-trip")
  }

  private func rank(_ text: String) throws -> SavingsGoalRank {
    guard let rank = SavingsGoalRank(text) else { throw MemoirFixtureError(description: "\(text) is not a rank") }
    return rank
  }

  private func settings() throws -> AccountSettingsRecord {
    let eur = try MemoirStoreFixture.currency("EUR")
    return AccountSettingsRecord(defaultCurrency: eur, enabledCurrencies: [eur])
  }

  private func olderMainStore(wallClock: @escaping @Sendable () -> Date) throws -> VaultStore {
    let registry = try SchemaRegistry(canonicalDescription: try MemoirStoreFixture.fixture("schema/registry-v5.json"))
    return try VaultStore.open(.inMemory, registry: registry, migrations: SyncEngine.migrations, wallClock: wallClock, admittedClasses: [.general])
  }

  @Test func shouldRoundTripTheBudgetSavingsAndGoalRecords() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let eur = try MemoirStoreFixture.currency("EUR")
    let jpy = try MemoirStoreFixture.currency("JPY")
    let day = try MemoirStoreFixture.date("2026-11-20")
    let december = try MemoirStoreFixture.date("2026-12-01")
    try await roundTrip(
      BudgetRecord(
        id: BudgetRecord.homeID, name: "Home", currency: eur, limitMinor: 150_000, period: .monthly, stagedLimit: StagedAmount(amountMinor: 180_000, from: december),
        oneOffFromMinor: 40_000, stagedOneOff: StagedAmount(amountMinor: 30_000, from: december), createdOn: day), in: store)
    try await roundTrip(
      BudgetRecord(
        id: Self.budget, name: "Kyoto", currency: jpy, limitMinor: 9_000_000, period: .trip(from: day, through: try MemoirStoreFixture.date("2026-11-30")), createdOn: day),
      in: store)
    try await roundTrip(BudgetRecord(id: Self.id, currency: eur, period: .monthly, createdOn: day), in: store)
    try await roundTrip(
      SavingsDepositRecord(
        budget: Self.budget, periodStart: december,
        deposit: SavingsDeposit(amountMinor: 1_250, currency: eur, rate: try MemoirStoreFixture.decimal("0.0061"), closedOn: day, command: Self.command)), in: store)
    try await roundTrip(
      SavingsDepositRecord(
        budget: BudgetRecord.homeID, periodStart: december, deposit: SavingsDeposit(amountMinor: 0, currency: eur, closedOn: day, command: Self.command)), in: store)
    try await roundTrip(
      SavingsGoalRecord(
        id: Self.goal, name: "New bike", symbol: "bicycle", targetMinor: 120_000, currency: eur, targetDate: try MemoirStoreFixture.date("2027-06-01"),
        rank: try rank("V"), createdOn: day, state: .known(.bought)), in: store)
    try await roundTrip(
      SavingsGoalRecord(id: Self.id, name: "Rainy day", symbol: "umbrella", targetMinor: 50_000, currency: eur, rank: try rank("a1"), createdOn: day, state: .unknown("paused")),
      in: store)
  }

  @Test func shouldRoundTripTheNewFieldsOfExistingKinds() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let eur = try MemoirStoreFixture.currency("EUR")
    let day = try MemoirStoreFixture.date("2026-11-20")
    let groceries = try MemoirStoreFixture.category("groceries")
    try await roundTrip(
      ExpenseRecord(
        id: Self.id, amountMinor: 999, currency: eur, occurredOn: day, category: groceries, budget: Self.budget, fromSavingsMinor: 400, goal: Self.goal,
        cycle: ExpenseCycleSeed(subscription: Self.id, amountMinor: 999, occurredOn: day, category: groceries, note: "Music"), loggedAtMillis: 5), in: store)
    try await roundTrip(
      SubscriptionRecord(
        id: Self.id, name: "Music", amountMinor: 999, currency: eur, frequency: .known(.monthly), billingDay: 3, anchorOn: day, category: groceries, budget: Self.budget),
      in: store)
    try await roundTrip(ExpenseCategoryRecord(key: groceries, label: "Groceries", essential: false), in: store)
    try await roundTrip(
      AccountSettingsRecord(
        defaultCurrency: eur, enabledCurrencies: [eur], moduleHero: false, moduleQuests: false, moduleMoney: true, moduleJournal: false, moduleMeals: false,
        moduleBody: false, moneyScoredFrom: day), in: store)
    let change = ExpenseChangeRecord(
      command: Self.command, expense: Self.id,
      changes: [.amount(from: 999, to: 0), .budget(from: nil, to: Self.budget), .fromSavings(from: 400, to: nil), .goal(from: Self.goal, to: nil)],
      reason: .known(.refund))
    _ = try await store.write { transaction in try change.append(in: &transaction) }
    #expect(try await store.read { transaction in try ExpenseChangeRecord.read(id: change.id, in: transaction) }.entry?.record == change)
  }

  @Test func shouldListTheNewExpenseFieldsAnEditMoved() throws {
    let day = try MemoirStoreFixture.date("2026-11-20")
    let before = ExpenseRecord(
      id: Self.id, amountMinor: 999, currency: try MemoirStoreFixture.currency("EUR"), occurredOn: day, category: try MemoirStoreFixture.category("groceries"),
      budget: Self.budget, loggedAtMillis: 5)
    var after = before
    after.budget = nil
    after.fromSavingsMinor = 300
    after.goal = Self.goal
    #expect(ExpenseFieldChange.changes(from: before, to: after) == [.budget(from: Self.budget, to: nil), .fromSavings(from: nil, to: 300), .goal(from: nil, to: Self.goal)])
    var cycled = before
    cycled.cycle = ExpenseCycleSeed(subscription: Self.id, amountMinor: 1, occurredOn: day, category: before.category)
    #expect(ExpenseFieldChange.changes(from: before, to: cycled).isEmpty, "the cycle seed is not the owner's edit")
    let seed = try #require(cycled.cycle)
    #expect(ExpenseCycleSeed(stored: seed.stored) == seed)
    #expect(seed.stored.objectValue?["subscription"] == .string(Self.id.lowercasedString))
    #expect(ExpenseCycleSeed(stored: ["amount_minor": 1, "occurred_on": "2026-11-20", "category": "groceries"]) == nil, "a seed names its subscription")
    for change in ExpenseFieldChange.changes(from: before, to: after) { #expect(ExpenseFieldChange(stored: change.stored) == change) }
    #expect(ExpenseFieldChange(stored: ["field": "budget", "from": "not-a-uuid"]) == nil)
  }

  @Test func shouldReadRecordsWrittenBeforeVersionSix() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let expense = ExpenseRecord.ref(Self.id)
    let subscription = SubscriptionRecord.ref(Self.id)
    let groceries = try MemoirStoreFixture.category("groceries")
    let change = ExpenseChangeRecord.ref(Self.command)
    _ = try await store.write { transaction in
      try transaction.set(
        expense, ["amount_minor": 999, "currency": "EUR", "occurred_on": "2026-11-20", "category": "groceries", "logged_at_millis": 5, "removed": false])
      try transaction.set(
        subscription,
        [
          "name": "Music", "amount_minor": 999, "currency": "EUR", "frequency": "monthly", "billing_day": 3, "anchor_on": "2026-11-20", "category": "groceries",
          "reminder_enabled": false, "reminder_lead": "on_day", "active": true, "removed": false,
        ])
      try transaction.set(MemoirKey.expenseCategory(groceries).ref, ["natural_key": MemoirKey.expenseCategory(groceries).stored, "label": "Groceries", "archived": false])
      try transaction.set(
        MemoirKey.accountSettings.ref,
        [
          "natural_key": MemoirKey.accountSettings.stored, "default_currency": "EUR", "enabled_currencies": ["EUR"], "schedule": ["start": 360, "end": 1380],
          "week_start": 1,
        ])
      try transaction.append(change, item: ["expense": .string(Self.id.lowercasedString), "changes": [["field": "amount_minor", "from": 999, "to": 500]]])
    }
    let expenseRead = try await store.read { transaction in try ExpenseRecord.read(expense, in: transaction) }.entry?.record
    #expect(expenseRead?.budget == nil && expenseRead?.fromSavingsMinor == nil && expenseRead?.goal == nil && expenseRead?.cycle == nil)
    #expect(expenseRead?.amountMinor == 999)
    #expect(try await store.read { transaction in try SubscriptionRecord.read(subscription, in: transaction) }.entry.map { $0.record.budget == nil } == true)
    let category = try await store.read { transaction in try ExpenseCategoryRecord.read(key: .expenseCategory(groceries), in: transaction) }.entry?.record
    #expect(category.map { $0.essential == nil } == true)
    let settings = try #require(try await store.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction) }.entry?.record)
    #expect(settings.modules == Set(MemoirModule.allCases))
    #expect(settings.moneyScoredFrom == nil)
    let changeRead = try await store.read { transaction in try ExpenseChangeRecord.read(id: Self.command, in: transaction) }.entry?.record
    #expect(changeRead == ExpenseChangeRecord(command: Self.command, expense: Self.id, changes: [.amount(from: 999, to: 500)]))
  }

  @Test func shouldKeepVersionSixFieldsThroughAnOlderDevicesEdit() async throws {
    let clock = MemoirTestClock()
    let newer = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let older = try olderMainStore(wallClock: clock.function)
    let expense = ExpenseRecord(
      id: Self.id, amountMinor: 999, currency: try MemoirStoreFixture.currency("EUR"), occurredOn: try MemoirStoreFixture.date("2026-11-20"),
      category: try MemoirStoreFixture.category("groceries"), budget: Self.budget, fromSavingsMinor: 400, goal: Self.goal, loggedAtMillis: 5)
    _ = try await newer.write { transaction in try expense.create(in: &transaction) }
    try await MemoirStoreFixture.exchange(newer, older)
    let seenByOlder = try await older.read { transaction in try ExpenseRecord.read(id: expense.id, in: transaction) }.entry?.record
    #expect(seenByOlder?.budget == nil, "an older registry holds the new fields apart and never reads them")
    clock.advance()
    _ = try await older.write { transaction in try ExpenseRecord.edit(id: expense.id, in: &transaction) { $0.note = "Shared" } }
    try await MemoirStoreFixture.exchange(newer, older)
    var expected = expense
    expected.note = "Shared"
    #expect(try await newer.read { transaction in try ExpenseRecord.read(id: expense.id, in: transaction) }.entry?.record == expected)
  }

  @Test func shouldKeepTheFirstDepositEitherDeviceRecordedWhole() async throws {
    let clock = MemoirTestClock()
    let first = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let second = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let eur = try MemoirStoreFixture.currency("EUR")
    let periodStart = try MemoirStoreFixture.date("2026-11-01")
    let closedOn = try MemoirStoreFixture.date("2026-12-04")
    let earlier = SavingsDeposit(amountMinor: 1_000, currency: eur, closedOn: closedOn, command: Self.command)
    let later = SavingsDeposit(
      amountMinor: 2_000, currency: eur, rate: try MemoirStoreFixture.decimal("0.0061"), closedOn: closedOn, command: MemoirStoreFixture.commandID(9))
    _ = try await second.write { transaction in try SavingsDepositRecord(budget: Self.budget, periodStart: periodStart, deposit: earlier).create(in: &transaction) }
    clock.advance()
    _ = try await first.write { transaction in try SavingsDepositRecord(budget: Self.budget, periodStart: periodStart, deposit: later).create(in: &transaction) }
    try await MemoirStoreFixture.exchange(first, second)
    for store in [first, second] {
      let read = try await store.read { transaction in try SavingsDepositRecord.read(key: .savingsDeposit(budget: Self.budget, periodStart: periodStart), in: transaction) }
      #expect(read.entry?.record.deposit == earlier, "the later close's rate must not fill the first deposit")
    }
    #expect(MemoirSchema.isRemovable(.savingsDeposit) == false)
  }

  @Test func shouldKeepTheFirstMoneyScoredFromAndBothDevicesModuleChanges() async throws {
    let clock = MemoirTestClock()
    let first = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let second = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    _ = try await first.write { transaction in try self.settings().create(in: &transaction) }
    try await MemoirStoreFixture.exchange(first, second)
    let november = try MemoirStoreFixture.date("2026-11-01")
    let december = try MemoirStoreFixture.date("2026-12-01")
    clock.advance()
    _ = try await second.write { transaction in
      try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { settings in
        settings.moneyScoredFrom = november
        settings.setModule(.meals, enabled: false)
      }
    }
    clock.advance()
    _ = try await first.write { transaction in
      try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { settings in
        settings.moneyScoredFrom = december
        settings.setModule(.money, enabled: false)
      }
    }
    try await MemoirStoreFixture.exchange(first, second)
    for store in [first, second] {
      let settings = try await store.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction) }.entry?.record
      #expect(settings?.moneyScoredFrom == november)
      #expect(settings?.modules == [.hero, .quests, .journal, .body])
    }
    let refused = try await first.write { transaction -> String? in
      do throws(MemoirRecordError) {
        try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { $0.moneyScoredFrom = december }
        return nil
      } catch {
        guard case .firstWriterField(_, let field) = error else { return "unexpected \(error)" }
        return field
      }
    }
    #expect(refused == "money_scored_from")
  }

  @Test func shouldKeepAnotherDevicesHomeLimitThroughALaterWriteThatOnlyEnsuresHome() async throws {
    let clock = MemoirTestClock()
    let first = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let lagging = try MemoirStore.openInMemory(.main, wallClock: clock.function)
    let eur = try MemoirStoreFixture.currency("EUR")
    let created = try MemoirStoreFixture.date("2026-11-20")
    let home = BudgetRecord(id: BudgetRecord.homeID, name: "Home", currency: eur, limitMinor: 150_000, period: .monthly, createdOn: created)
    _ = try await first.write { transaction in try home.create(in: &transaction) }
    clock.advance()
    _ = try await first.write { transaction in try BudgetRecord.edit(id: BudgetRecord.homeID, in: &transaction) { $0.limitMinor = 100_000 } }
    clock.advance()
    let ensured = BudgetRecord(id: BudgetRecord.homeID, currency: eur, period: .monthly, createdOn: try MemoirStoreFixture.date("2026-11-25"))
    let written = try await lagging.write { transaction in try ensured.create(in: &transaction) }
    #expect(written.first.map { Set($0.fields.keys) } == ["currency", "period", "created_on", "removed"])
    try await MemoirStoreFixture.exchange(first, lagging)
    var expected = home
    expected.limitMinor = 100_000
    for store in [first, lagging] {
      #expect(try await store.read { transaction in try BudgetRecord.read(id: BudgetRecord.homeID, in: transaction) } == .readable(MemoirEntry(record: expected, isRemoved: false)))
    }
  }

  @Test func shouldRefuseMovingABudgetsOrGoalsFirstWriterFields() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let eur = try MemoirStoreFixture.currency("EUR")
    let usd = try MemoirStoreFixture.currency("USD")
    let day = try MemoirStoreFixture.date("2026-11-20")
    let budget = BudgetRecord(id: Self.budget, name: "Home", currency: eur, limitMinor: 100, period: .monthly, createdOn: day)
    let goal = SavingsGoalRecord(id: Self.goal, name: "Bike", symbol: "bicycle", targetMinor: 100, currency: eur, rank: try rank("V"), createdOn: day)
    _ = try await store.write { transaction in
      try budget.create(in: &transaction)
      try goal.create(in: &transaction)
    }
    let attempts: [(String, @Sendable (inout WriteTransaction) throws(MemoirRecordError) -> Void)] = [
      ("currency", { transaction throws(MemoirRecordError) in try BudgetRecord.edit(id: Self.budget, in: &transaction) { $0.currency = usd } }),
      ("created_on", { transaction throws(MemoirRecordError) in try BudgetRecord.edit(id: Self.budget, in: &transaction) { $0.createdOn = day.adding(days: 1) ?? day } }),
      ("currency", { transaction throws(MemoirRecordError) in try SavingsGoalRecord.edit(id: Self.goal, in: &transaction) { $0.currency = usd } }),
      ("created_on", { transaction throws(MemoirRecordError) in try SavingsGoalRecord.edit(id: Self.goal, in: &transaction) { $0.createdOn = day.adding(days: 1) ?? day } }),
    ]
    for (field, attempt) in attempts {
      let refused = try await store.write { transaction -> String? in
        do throws(MemoirRecordError) {
          try attempt(&transaction)
          return nil
        } catch {
          guard case .firstWriterField(_, let refused) = error else { return "unexpected \(error)" }
          return refused
        }
      }
      #expect(refused == field)
    }
    let changes = try await store.write { transaction in
      try BudgetRecord.edit(id: Self.budget, in: &transaction) { budget in
        budget.limitMinor = 90
        budget.period = .trip(from: day, through: day)
      }
    }
    #expect(changes.first.map { Set($0.fields.keys) } == ["limit_minor", "period"])
  }

  @Test func shouldReadModulesAsOnUntilTurnedOff() throws {
    var settings = try settings()
    #expect(settings.modules == Set(MemoirModule.allCases))
    #expect(MemoirModule.allCases.map(\.rawValue) == ["hero", "quests", "money", "journal", "meals", "body"])
    settings.setModule(.quests, enabled: false)
    settings.setModule(.body, enabled: false)
    #expect(settings.modules == [.hero, .money, .journal, .meals])
    #expect(settings.moduleQuests == false && settings.moduleBody == false && settings.moduleHero == nil)
    #expect(!settings.isEnabled(.quests) && settings.isEnabled(.hero))
    settings.setModule(.quests, enabled: true)
    #expect(settings.moduleQuests == true)
    #expect(settings.modules == [.hero, .quests, .money, .journal, .meals])
    #expect(settings.members.values["module_quests"] == .bool(true))
    #expect(settings.members.values["module_hero"] == nil)
  }

  @Test func shouldRefuseABudgetPeriodThatIsNotAValidSpan() throws {
    let from = try MemoirStoreFixture.date("2026-11-20")
    let through = try MemoirStoreFixture.date("2026-11-25")
    #expect(BudgetPeriodKind(stored: BudgetPeriodKind.trip(from: from, through: through).stored) == .trip(from: from, through: through))
    #expect(BudgetPeriodKind(stored: BudgetPeriodKind.trip(from: from, through: from).stored) == .trip(from: from, through: from))
    #expect(BudgetPeriodKind(stored: BudgetPeriodKind.monthly.stored) == .monthly)
    #expect(BudgetPeriodKind.monthly.stored == ["kind": "monthly"])
    let refused: [JSONValue] = [
      ["kind": "trip", "from": "2026-11-25", "through": "2026-11-20"], ["kind": "trip", "from": "2026-11-25"], ["kind": "monthly", "from": "2026-11-25"],
      ["kind": "weekly"], ["kind": "monthly", "extra": 1], "monthly", ["kind": "trip", "from": "2026-11-20", "through": "25 November"],
    ]
    for json in refused { #expect(BudgetPeriodKind(stored: json) == nil, "\(json)") }
  }

  @Test func shouldReadABudgetWithAMalformedPeriodAsUnreadable() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let ref = BudgetRecord.ref(Self.budget)
    _ = try await store.write { transaction in
      try transaction.set(
        ref,
        [
          "name": "Trip", "currency": "EUR", "limit_minor": 100, "created_on": "2026-11-20", "removed": false,
          "period": ["kind": "trip", "from": "2026-11-25", "through": "2026-11-20"],
        ])
    }
    #expect(try await store.read { transaction in try BudgetRecord.read(ref, in: transaction) } == .unreadable(.invalid(field: "period")))
  }

  @Test func shouldOrderGoalRanksByTheirBytesAndRefuseRanksWithoutRoomBelow() throws {
    #expect(try rank("0V") < (try rank("1")))
    #expect(try rank("Z") < (try rank("a")))
    #expect(try rank("a") < (try rank("a1")))
    #expect(try rank("9") < (try rank("A")))
    for text in ["", "0", "a0", "a-b", "é", String(repeating: "a", count: SavingsGoalRank.maximumLength + 1)] { #expect(SavingsGoalRank(text) == nil, "\(text)") }
    #expect(SavingsGoalRank(String(repeating: "a", count: SavingsGoalRank.maximumLength)) != nil)
  }

  @Test func shouldPinTheHomeBudgetIDSoEveryDeviceCreatesTheSameHome() throws {
    #expect(BudgetRecord.homeID == derivedID("com.shadow.library.memoircore.home-budget", "home"))
    #expect(BudgetRecord.homeID.lowercasedString == "3364af55-09e9-822b-995c-b9c94bddfa52")
    let eur = try MemoirStoreFixture.currency("EUR")
    let day = try MemoirStoreFixture.date("2026-11-20")
    #expect(BudgetRecord(id: BudgetRecord.homeID, currency: eur, period: .monthly, createdOn: day).isHome)
    #expect(!BudgetRecord(id: Self.budget, currency: eur, period: .monthly, createdOn: day).isHome)
  }
}
