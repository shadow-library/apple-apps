import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Money reads", TestTimeLimit.standard)
struct MoneyReadsTests {
  private static let today = MoneyReadsFixture.date("2026-11-21")

  /// EUR home; this week: 12.00 EUR food, 50.00 USD with its rate, 1,000 JPY and 1.500 KWD without one; earlier this month 8.00 EUR groceries.
  private static func seeded() async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(
      stores.main,
      [
        MoneyReadsFixture.settings(budgetMinor: 20_000),
        MoneyReadsFixture.expense(1, 1200, "EUR", on: "2026-11-20", merchant: "Café Rot", note: "Lunch"),
        MoneyReadsFixture.expense(2, 5000, "USD", on: "2026-11-19", category: "shopping", merchant: "Books"),
        MoneyReadsFixture.expense(3, 1000, "JPY", on: "2026-11-19", category: "transport"),
        MoneyReadsFixture.expense(4, 1500, "KWD", on: "2026-11-17", category: "transport"),
        MoneyReadsFixture.expense(5, 800, "EUR", on: "2026-11-02", category: "groceries"),
        MoneyReadsFixture.expense(6, 400, "EUR", on: "2026-10-15", category: "food"),
        MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-19", "0.9"),
      ])
    return stores
  }

  @Test func shouldLeaveExpensesWaitingForARateOutOfHomeTotalsAndCountThem() async throws {
    let stores = try await Self.seeded()
    let overview = try #require(try await MoneyReads.overview(in: stores, today: Self.today))
    #expect(overview.home == MoneyReadsFixture.currency("EUR"))
    #expect(overview.week.spent.totalMinor == 1200 + 4500, "12.00 EUR plus 50.00 USD at 0.9")
    #expect(
      overview.week.spent.pending == PendingConversions(awaitingRate: 2, unconvertible: 0, currencies: [MoneyReadsFixture.currency("JPY"), MoneyReadsFixture.currency("KWD")]))
    #expect(overview.month.spent.totalMinor == 1200 + 4500 + 800)
    #expect(overview.month.daysLogged == 4, "days with an expense, waiting ones included, as the web counts them")
    #expect(overview.month.averagePerDayMinor == 1625, "6,500 over four days")
    #expect(overview.month.comparison == DateSpan(start: MoneyReadsFixture.date("2026-10-01"), end: MoneyReadsFixture.date("2026-10-21")))
    #expect(overview.month.previousMinor == 400)
    #expect(overview.month.delta == Fraction(numerator: 6500 - 400, denominator: 400))
    #expect(overview.budget?.spend.spentMinor == 6500)
    #expect(overview.budget?.spend.awaitingRate == 2)
    #expect(overview.budget?.leftMinor == 13_500)
    #expect(overview.budget?.daysLeft == 10)
    #expect(overview.expensesThisMonth == 5)

    let currencies = overview.week.currencies
    #expect(currencies.map(\.currency.code) == ["EUR", "JPY", "KWD", "USD"])
    #expect(currencies.first { $0.currency.code == "JPY" }?.totalMinor == 1000, "own-currency totals keep each currency's minor units")
    #expect(currencies.first { $0.currency.code == "KWD" }?.home.pending.awaitingRate == 1)
    #expect(currencies.first { $0.currency.code == "USD" }?.home.totalMinor == 4500)
  }

  /// `categoryBreakdown` (`finance.rules.ts:166-181`): largest first, each against the largest, halves up.
  @Test func shouldBreakSpendingDownByCategoryAgainstTheLargest() async throws {
    let stores = try await Self.seeded()
    let overview = try #require(try await MoneyReads.overview(in: stores, today: Self.today))
    let slices = overview.month.categories
    #expect(slices.map(\.category.key) == ["shopping", "food", "groceries", "transport"])
    #expect(slices.map(\.percentOfLargest) == [100, 27, 18, 0])
    #expect(slices.last?.count == 2 && slices.last?.pending.awaitingRate == 2, "a category whose expenses all wait is listed with a zero total")
  }

  /// With the rates recorded, JPY (exponent 0) and KWD (exponent 3) convert with their exponents applied (decision 7).
  @Test func shouldConvertZeroAndThreeDecimalCurrenciesWithTheirExponents() async throws {
    let stores = try await Self.seeded()
    try await MoneyReadsFixture.seed(
      stores.main, [MoneyReadsFixture.rate("JPY", "EUR", on: "2026-11-19", "0.0062"), MoneyReadsFixture.rate("KWD", "EUR", on: "2026-11-17", "2.95")])
    let overview = try #require(try await MoneyReads.overview(in: stores, today: Self.today))
    let transport = try #require(overview.week.categories.first { $0.category.key == "transport" })
    #expect(transport.totalMinor == 620 + 443, "¥1,000 at 0.0062 is €6.20; KWD 1.500 at 2.95 is €4.425, halves up to €4.43")
    #expect(transport.pending == .none)
  }

  @Test func shouldListExpensesNewestFirstFilteredSearchedAndPaged() async throws {
    let stores = try await Self.seeded()
    let month = DateSpan.month(of: Self.today)
    let all = try await MoneyReads.expenses(in: stores, matching: ExpenseQuery(span: month))
    #expect(all.rows.items.map(\.expense.id) == [1, 3, 2, 4, 5].map(MoneyReadsFixture.id), "by date, then logged time, then id, all descending")
    #expect(all.rows.items.first { $0.expense.currency.code == "JPY" }?.inHome == .awaitingRate)
    let searched = try await MoneyReads.expenses(in: stores, matching: ExpenseQuery(span: nil, search: "  café "))
    #expect(searched.rows.items.map(\.expense.id) == [MoneyReadsFixture.id(1)], "the note and merchant are matched, case-insensitively")
    let byCategory = try await MoneyReads.expenses(in: stores, matching: ExpenseQuery(span: nil, category: MoneyReadsFixture.category("transport")))
    #expect(byCategory.rows.total == 2)
    let page = try await MoneyReads.expenses(in: stores, matching: ExpenseQuery(span: nil, page: try PageRequest(offset: 4, limit: 4)))
    #expect(page.rows.total == 6)
    #expect(page.rows.items.map(\.expense.id) == [MoneyReadsFixture.id(5), MoneyReadsFixture.id(6)])
    #expect(!page.rows.hasMore)
    #expect(throws: MemoirReadError.self) { try PageRequest(offset: -1, limit: 4) }
    #expect(throws: MemoirReadError.self) { try PageRequest(offset: 0, limit: 0) }
  }

  @Test func shouldReadNothingButDefaultsBeforeTheVaultHasSettings() async throws {
    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.expense(1, 100, "USD", on: "2026-11-20")])
    #expect(try await MoneyReads.subscriptions(in: stores, today: Self.today) == nil)
    let listing = try await MoneyReads.expenses(in: stores, matching: ExpenseQuery(span: nil))
    #expect(listing.home == nil)
    #expect(listing.rows.items.map(\.inHome) == [.awaitingRate])
    #expect(try await MoneyReads.categories(in: stores, today: Self.today).thisMonth == nil)
  }

  @Test func shouldListSubscriptionsWithDueStatesTotalsUpcomingAndCollisions() async throws {
    let stores = try MemoirStores.openInMemory()
    let gym = SubscriptionRecord(
      id: MoneyReadsFixture.id(10), name: "Gym", amountMinor: 3000, currency: MoneyReadsFixture.currency("EUR"), frequency: .known(.monthly), billingDay: 25,
      anchorOn: MoneyReadsFixture.date("2026-11-25"), category: MoneyReadsFixture.category("health"), reminderEnabled: true, reminderLead: .known(.threeDays))
    let music = SubscriptionRecord(
      id: MoneyReadsFixture.id(11), name: "Music", amountMinor: 12_000, currency: MoneyReadsFixture.currency("USD"), frequency: .known(.yearly), billingDay: 25,
      anchorOn: MoneyReadsFixture.date("2026-11-25"), category: MoneyReadsFixture.category("subs"))
    let paper = SubscriptionRecord(
      id: MoneyReadsFixture.id(12), name: "Paper", amountMinor: 1000, currency: MoneyReadsFixture.currency("JPY"), frequency: .known(.weekly), billingDay: 1,
      anchorOn: MoneyReadsFixture.date("2026-11-18"), category: MoneyReadsFixture.category("subs"))
    let paused = SubscriptionRecord(
      id: MoneyReadsFixture.id(13), name: "Paused", amountMinor: 500, currency: MoneyReadsFixture.currency("EUR"), frequency: .known(.monthly), billingDay: 1,
      anchorOn: MoneyReadsFixture.date("2026-11-01"), category: MoneyReadsFixture.category("subs"), active: false)
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(), gym, music, paper, paused, MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-01", "0.9")])
    var overview = try #require(try await MoneyReads.subscriptions(in: stores, today: Self.today))
    #expect(overview.items.map(\.subscription.name) == ["Paused", "Paper", "Gym", "Music"])
    let byName = Dictionary(uniqueKeysWithValues: overview.items.map { ($0.subscription.name, $0) })
    #expect(byName["Gym"]?.dueState == SubscriptionDueState.none, "four days out, past a three-day reminder lead")
    #expect(byName["Gym"]?.reminderOn == MoneyReadsFixture.date("2026-11-22"))
    #expect(byName["Music"]?.dueState == .upcoming, "no reminder: the seven-day default window")
    #expect(byName["Paper"]?.dueState == .overdue)
    #expect(byName["Paused"]?.dueState == SubscriptionDueState.none)
    #expect(overview.totals.activeCount == 3)
    #expect(overview.totals.monthlyMinor == 3000 + 900, "EUR 30 and USD 120 a year, 10 a month at 0.9; the yen paper waits for a rate")
    #expect(overview.totals.yearlyMinor == 12 * 3900)
    #expect(overview.totals.pending.currencies == [MoneyReadsFixture.currency("JPY")])
    #expect(byName["Paper"]?.monthlyEquivalent.amountMinor == 4333, "weekly: ×52/12, truncated as the reference's BigInt")
    #expect(overview.highlight == .overdue(subscription: paper.id, dueOn: MoneyReadsFixture.date("2026-11-18"), count: 1))
    #expect(overview.upcoming.map(\.subscription) == [gym.id, music.id])
    let collision = try #require(overview.collisions.first)
    #expect(collision.date == MoneyReadsFixture.date("2026-11-25"))
    #expect(collision.totalMinor == Int64(3000 + 10_800))

    try await MoneyReadsFixture.write(stores.main) { transaction in
      try MoneyReadsFixture.issuer(on: Self.today).confirmCycle(CycleConfirmation(subscription: paper.id, billingDate: MoneyReadsFixture.date("2026-11-18")), in: &transaction)
    }
    overview = try #require(try await MoneyReads.subscriptions(in: stores, today: Self.today))
    let confirmed = try #require(overview.items.first { $0.subscription.id == paper.id })
    #expect(confirmed.lastConfirmed == MoneyReadsFixture.date("2026-11-18"))
    #expect(confirmed.nextDue == MoneyReadsFixture.date("2026-11-25"))
    #expect(overview.highlight == .next(subscription: gym.id, dueOn: MoneyReadsFixture.date("2026-11-25")), "three renew that day; the first by id")
    #expect(overview.collisions.first?.unconverted == [MoneyAmount(amountMinor: 1000, currency: MoneyReadsFixture.currency("JPY"))])
  }

  @Test func shouldListCategoriesWithTheirArchivedState() async throws {
    let stores = try await Self.seeded()
    try await MoneyReadsFixture.seed(
      stores.main,
      [
        ExpenseCategoryRecord(key: MoneyReadsFixture.category("home"), label: "Home", archived: true),
        ExpenseCategoryRecord(key: MoneyReadsFixture.category("pets"), label: "Pets"),
      ])
    let overview = try await MoneyReads.categories(in: stores, today: Self.today)
    #expect(overview.categories.map(\.key.key) == ["food", "groceries", "transport", "bills", "health", "shopping", "home", "subs", "uncat", "pets"])
    #expect(overview.categories.first { $0.key.key == "home" }?.isArchived == true)
    #expect(overview.categories.first { $0.key.key == "uncat" }?.isPermanent == true)
    #expect(overview.categories.first { $0.key.key == "pets" }?.isBuiltIn == false)
    #expect(overview.thisMonth?.count == 10, "every category, spent on or not")
    #expect(overview.uncategorised?.count == 0)
  }

  private static func refusal(_ body: @escaping @Sendable (inout WriteTransaction) throws -> Void, in store: VaultStore) async -> CommandIssueError? {
    do {
      try await store.write { transaction in try body(&transaction) }
      return nil
    } catch {
      guard case .aborted(let inner as CommandIssueError) = error else { return nil }
      return inner
    }
  }

  private static func changeRecords(_ stores: MemoirStores) async throws -> Int {
    try await stores.main.read { transaction in try ExpenseChangeRecord.listing(in: transaction).entries.count }
  }

  private static func issuer(hour: Int, on day: String = "2026-11-21") -> CommandIssuer {
    MoneyReadsFixture.issuer(on: MoneyReadsFixture.date(day), hour: hour)
  }

  @Test func shouldReadAnExpensesHistoryAsTypedDiffsFromItsCommands() async throws {
    let stores = try MemoirStores.openInMemory()
    let id = MoneyReadsFixture.id(1)
    let created = MoneyReadsFixture.expense(1, 1250, "EUR", on: "2026-11-20", merchant: "Café")
    try await MoneyReadsFixture.write(stores.main) { transaction in try ExpenseEdits.create(created, issuer: Self.issuer(hour: 9, on: "2026-11-20"), in: &transaction) }

    let currency = await Self.refusal(
      { transaction in
        try ExpenseEdits.update(id, issuer: Self.issuer(hour: 8), in: &transaction) { expense in
          expense.amountMinor = 99
          expense.currency = MoneyReadsFixture.currency("USD")
        }
      }, in: stores.main)
    guard case .refused(.finance(.expenseFieldFixed("currency")))? = currency else {
      Issue.record("moving the currency is FIN_006, not \(String(describing: currency))")
      return
    }
    let logged = await Self.refusal(
      { transaction in
        try ExpenseEdits.update(id, issuer: Self.issuer(hour: 8), in: &transaction) { $0.loggedAtMillis += 1 }
      }, in: stores.main)
    guard case .refused(.finance(.expenseFieldFixed("logged_at_millis")))? = logged else {
      Issue.record("the logging time is fixed, not \(String(describing: logged))")
      return
    }

    let edit = try await stores.main.write { transaction in
      try ExpenseEdits.update(id, issuer: Self.issuer(hour: 9), in: &transaction) { expense in
        expense.amountMinor = 1500
        expense.merchant = nil
      }
    }
    #expect(edit != nil)
    let unchanged = try await stores.main.write { transaction in try ExpenseEdits.update(id, issuer: Self.issuer(hour: 10), in: &transaction) { $0.note = "" } }
    #expect(unchanged == nil, "an edit that moves nothing the owner sees writes nothing")
    try await MoneyReadsFixture.write(stores.main) { transaction in
      try Self.issuer(hour: 11).issue(.expenseUpdate(RecordReference(id: id)), in: &transaction)
      let future = try MemoirCommand(
        id: MemoirStoreFixture.commandID(77), payload: try CommandPayload(type: try CommandType("expense.split")), instantMillis: MoneyReadsFixture.millis(Self.today),
        utcOffsetMinutes: 0, issuedOn: Self.today, rulesetVersion: 1)
      try future.append(in: &transaction)
    }
    var history = try await MoneyReads.history(of: id, in: stores)
    #expect(history.expense.entry?.record.amountMinor == 1500)
    #expect(history.expense.entry?.record.currency == MoneyReadsFixture.currency("EUR"))
    #expect(
      history.entries.map(\.action) == [
        .updated(changes: nil), .updated(changes: [.amount(from: 1250, to: 1500), .merchant(from: "Café", to: nil)]), .created(source: .manual),
      ])
    #expect(history.unreadableCommands == 1, "a newer device's command type is counted, not dropped")
    #expect(try await Self.changeRecords(stores) == 1)

    try await MoneyReadsFixture.write(stores.main) { transaction in try ExpenseEdits.delete(id, issuer: Self.issuer(hour: 12), in: &transaction) }
    #expect(try await Self.changeRecords(stores) == 0, "the deletion purges the change records holding the old merchant")
    let purged = try await stores.main.read { transaction in
      try transaction.states(ofKind: MemoirKind.expenseChange.entityKind, scope: .vault).allSatisfy { if case .purged = $0.state { true } else { false } }
    }
    #expect(purged)
    history = try await MoneyReads.history(of: id, in: stores)
    #expect(history.expense.entry?.isRemoved == true)
    #expect(history.entries.map(\.action) == [.deleted, .updated(changes: nil), .updated(changes: nil), .created(source: .manual)], "only the commands remain")
    let afterDelete = await Self.refusal(
      { transaction in
        try ExpenseEdits.update(id, issuer: Self.issuer(hour: 13), in: &transaction) { $0.amountMinor = 1 }
      }, in: stores.main)
    guard case .record(.absent(let ref))? = afterDelete, ref == ExpenseRecord.ref(id) else {
      Issue.record("a deleted expense is absent to an edit, not \(String(describing: afterDelete))")
      return
    }

    let otherCurrency = await Self.refusal(
      { transaction in
        try ExpenseEdits.create(MoneyReadsFixture.expense(1, 700, "USD", on: "2026-11-21"), issuer: Self.issuer(hour: 14), in: &transaction)
      }, in: stores.main)
    guard case .refused(.finance(.expenseFieldFixed("currency")))? = otherCurrency else {
      Issue.record("an id keeps its first currency, not \(String(describing: otherCurrency))")
      return
    }
    try await MoneyReadsFixture.write(stores.main) { transaction in
      try ExpenseEdits.create(MoneyReadsFixture.expense(1, 700, "EUR", on: "2026-11-21", note: "again"), issuer: Self.issuer(hour: 15), in: &transaction)
    }
    history = try await MoneyReads.history(of: id, in: stores)
    #expect(history.expense.entry?.isRemoved == false)
    #expect(history.expense.entry?.record.amountMinor == 700)
    #expect(history.expense.entry?.record.loggedAtMillis == created.loggedAtMillis, "the first logging time is kept")
    #expect(history.entries.map(\.action) == [.created(source: .manual)], "a creation starts the history again, as the reference clears the audit")
    let duplicate = await Self.refusal(
      { transaction in
        try ExpenseEdits.create(MoneyReadsFixture.expense(1, 700, "EUR", on: "2026-11-21"), issuer: Self.issuer(hour: 16), in: &transaction)
      }, in: stores.main)
    guard case .refused(.finance(.expenseExists(id)))? = duplicate else {
      Issue.record("a live id is not created twice, not \(String(describing: duplicate))")
      return
    }
  }

  /// The reference deletes the row outright (`expense.repository.ts:53-59`); a removed record keeps its fields, so a deletion clears the owner's words.
  @Test func shouldLeaveNoNoteOrMerchantOfADeletedExpenseInTheMainStore() async throws {
    let stores = try MemoirStores.openInMemory()
    let expense = MoneyReadsFixture.expense(1, 1250, "EUR", on: "2026-11-20", merchant: "Zebrabakery", note: "Quokkalunch")
    try await MoneyReadsFixture.write(stores.main) { transaction in try ExpenseEdits.create(expense, issuer: Self.issuer(hour: 9), in: &transaction) }
    try await MoneyReadsFixture.write(stores.main) { transaction in
      try ExpenseEdits.update(expense.id, issuer: Self.issuer(hour: 10), in: &transaction) { $0.note = "Quokkadinner" }
    }
    try await MoneyReadsFixture.write(stores.main) { transaction in try ExpenseEdits.delete(expense.id, issuer: Self.issuer(hour: 11), in: &transaction) }
    let hits = try await stores.main.read { transaction in
      var count = 0
      for table in ["field_state", "appended_item"] {
        for column in ["value", "item"] where try transaction.database.columns(in: table).contains(where: { $0.name == column }) {
          let sql = "SELECT COUNT(*) FROM \(table) WHERE CAST(\(column) AS TEXT) LIKE '%Zebrabakery%' OR CAST(\(column) AS TEXT) LIKE '%Quokka%'"
          count += try Int.fetchOne(transaction.database, sql: sql) ?? 0
        }
      }
      return count
    }
    #expect(hits == 0, "neither the merchant nor any note survives the deletion")
    let reading = try await stores.main.read { try ExpenseRecord.read(id: expense.id, in: $0) }
    #expect(reading.entry?.isRemoved == true && reading.entry?.record.note == nil && reading.entry?.record.merchant == nil)
  }

  @Test func shouldPurgeAChangeRecordThisVersionCannotRead() async throws {
    let stores = try MemoirStores.openInMemory()
    let id = MoneyReadsFixture.id(1)
    try await MoneyReadsFixture.write(stores.main) { transaction in
      try ExpenseEdits.create(MoneyReadsFixture.expense(1, 100, "EUR", on: "2026-11-20"), issuer: Self.issuer(hour: 9), in: &transaction)
      _ = try transaction.append(
        ExpenseChangeRecord.ref(MemoirStoreFixture.commandID(88)),
        item: ["expense": id.stored, "changes": .array([]), "split": .string("newer")])
    }
    let unreadable = try await stores.main.read { try ExpenseChangeRecord.listing(in: $0).unreadable }
    #expect(unreadable == 1)
    try await MoneyReadsFixture.write(stores.main) { transaction in try ExpenseEdits.delete(id, issuer: Self.issuer(hour: 10), in: &transaction) }
    let remaining = try await stores.main.read { transaction in
      try transaction.states(ofKind: MemoirKind.expenseChange.entityKind, scope: .vault).filter { if case .purged = $0.state { false } else { true } }.count
    }
    #expect(remaining == 0, "a newer device's change record of the expense is purged by its stored expense id")
  }

  @Test func shouldReEmitTheOverviewWhenAnExpenseIsWritten() async throws {
    let stores = try await Self.seeded()
    var iterator = MoneyReads.observeOverview(in: stores, today: Self.today).makeAsyncIterator()
    let first = try #require(try await iterator.next() ?? nil)
    #expect(first.week.spent.totalMinor == 5700)
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.expense(7, 300, "EUR", on: "2026-11-21")])
    let second = try #require(try await iterator.next() ?? nil)
    #expect(second.week.spent.totalMinor == 6000)
  }
}
