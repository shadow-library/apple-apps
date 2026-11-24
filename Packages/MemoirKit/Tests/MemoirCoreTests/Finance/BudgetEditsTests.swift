import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Budget edits", TestTimeLimit.quick)
struct BudgetEditsTests {
  private typealias F = BudgetFixture

  private static let today = F.date("2026-11-21")
  private static let dollars = F.id(1)
  private static let trip = F.id(2)
  private static let other = F.id(3)

  private static func create(_ draft: BudgetDraft, _ id: UUID, on day: LocalDate = today, in store: VaultStore) async throws {
    _ = try await store.write { transaction in try BudgetEdits.create(draft, id: id, today: day, in: &transaction) }
  }

  @discardableResult
  private static func update(_ id: UUID, on day: LocalDate = today, in store: VaultStore, _ change: @escaping @Sendable (inout BudgetDraft) -> Void) async throws
    -> BudgetRecord?
  {
    try await store.write { transaction in try BudgetEdits.update(id, today: day, in: &transaction, change) }
  }

  private static func live(_ id: UUID, in store: VaultStore) async throws -> LiveBudget {
    try #require(try await F.budgets(in: store).budget(id))
  }

  @Test func shouldCreateABudgetAndMakeSureHomeExistsInTheSameWrite() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly(" Dollars ", F.usd, limitMinor: 30_000), Self.dollars, in: store)

    let budgets = try await F.budgets(in: store)
    #expect(budgets.live.map(\.id) == [HomeBudget.id, Self.dollars])
    #expect(budgets.homeCurrency == F.eur)
    let dollars = try #require(budgets.budget(Self.dollars))
    #expect(dollars.record == BudgetRecord(id: Self.dollars, name: "Dollars", currency: F.usd, limitMinor: 30_000, period: .monthly, createdOn: Self.today))
    #expect(try await F.record(HomeBudget.id, in: store) == BudgetRecord(id: HomeBudget.id, currency: F.eur, period: .monthly, createdOn: Self.today))
    #expect(budgets.home?.limitMinor(on: Self.today) == 50_000, "Home's limit is the account's monthly budget until one is written")
  }

  @Test func shouldRefuseEveryBudgetThatBreaksARule() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)
    try await Self.create(F.trip("Lisbon", F.eur, limitMinor: 90_000, from: "2026-12-10", through: "2026-12-20"), Self.trip, in: store)
    let cases: [(BudgetDraft, UUID, FinanceError)] = [
      (BudgetDraft(currency: F.gbp, limitMinor: 1, period: .monthly), Self.other, .budgetNameRequired),
      (BudgetDraft(name: " \n", currency: F.gbp, limitMinor: 1, period: .monthly), Self.other, .budgetNameRequired),
      (BudgetDraft(name: "Pounds", currency: F.gbp, period: .monthly), Self.other, .budgetLimitRequired),
      (F.monthly("Pounds", F.gbp, limitMinor: -1), Self.other, .negativeLimit(-1)),
      (F.monthly("Pounds", F.gbp, limitMinor: 1, oneOffFromMinor: -5), Self.other, .negativeLimit(-5)),
      (F.monthly("Gold", F.currency("XAU"), limitMinor: 1), Self.other, .unknownCurrency(F.currency("XAU"))),
      (F.trip("Back to front", F.gbp, limitMinor: 1, from: "2026-12-02", through: "2026-12-01"), Self.other, .invalidTripDates),
      (F.monthly("Euros", F.eur, limitMinor: 1), Self.other, .currencyTaken(F.eur)),
      (F.monthly("More dollars", F.usd, limitMinor: 1), Self.other, .currencyTaken(F.usd)),
      (F.trip("Porto", F.eur, limitMinor: 1, from: "2026-12-20", through: "2026-12-22"), Self.other, .tripsOverlap(Self.trip)),
      (F.monthly("Pounds", F.gbp, limitMinor: 1), Self.dollars, .budgetExists(Self.dollars)),
      (F.monthly("Home", F.gbp, limitMinor: 1), HomeBudget.id, .homeBudgetFixed),
    ]
    for (draft, id, expected) in cases {
      let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.create(draft, id: id, today: Self.today, in: &transaction) }
      #expect(refused == expected, "\(draft)")
    }
    #expect(try await F.budgets(in: store).live.map(\.id) == [HomeBudget.id, Self.dollars, Self.trip])
  }

  @Test func shouldTreatTripsSharingAnEndDayAsOverlappingAndAdjacentTripsAsApart() async throws {
    let store = try await F.store()
    try await Self.create(F.trip("Lisbon", F.eur, limitMinor: 1, from: "2026-12-10", through: "2026-12-20"), Self.trip, in: store)
    let overlapping = [("2026-12-20", "2026-12-25"), ("2026-12-01", "2026-12-10"), ("2026-12-01", "2026-12-31"), ("2026-12-12", "2026-12-12")]
    for (from, through) in overlapping {
      let draft = F.trip("Other", F.usd, limitMinor: 1, from: from, through: through)
      let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.create(draft, id: Self.other, today: Self.today, in: &transaction) }
      #expect(refused == .tripsOverlap(Self.trip), "\(from)…\(through)")
    }
    try await Self.create(F.trip("Before", F.usd, limitMinor: 1, from: "2026-12-01", through: "2026-12-09"), Self.other, in: store)
    try await Self.create(F.trip("After", F.usd, limitMinor: 1, from: "2026-12-21", through: "2026-12-21"), Self.dollars, in: store)
    _ = try await store.write { transaction in try BudgetEdits.delete(Self.trip, in: &transaction) }
    try await Self.create(F.trip("Instead", F.usd, limitMinor: 1, from: "2026-12-10", through: "2026-12-20"), F.id(9), in: store)
    #expect(try await F.budgets(in: store).live.count == 4, "a deleted trip holds no dates")
  }

  @Test func shouldKeepHomesNameCurrencyAndPeriodAndRefuseDeletingIt() async throws {
    let store = try await F.store()
    let changes: [@Sendable (inout BudgetDraft) -> Void] = [
      { $0.name = "Everyday" }, { $0.currency = F.usd }, { $0.period = .trip(from: Self.today, through: Self.today) },
    ]
    for change in changes {
      let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.update(HomeBudget.id, today: Self.today, in: &transaction, change) }
      #expect(refused == .homeBudgetFixed)
    }
    #expect(try await F.refusal(in: store) { transaction throws(FinanceError) in try BudgetEdits.delete(HomeBudget.id, in: &transaction) } == .homeBudgetFixed)
    #expect(
      try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.update(HomeBudget.id, today: Self.today, in: &transaction) { $0.limitMinor = nil } }
        == .budgetLimitRequired)
  }

  @Test func shouldKeepAnotherBudgetsCurrencyAndKindAndRequireItsNameAndLimit() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)
    try await Self.create(F.trip("Lisbon", F.eur, limitMinor: 1, from: "2026-12-10", through: "2026-12-20"), Self.trip, in: store)
    let cases: [(UUID, @Sendable (inout BudgetDraft) -> Void, FinanceError)] = [
      (Self.dollars, { $0.currency = F.gbp }, .budgetFieldFixed("currency")),
      (Self.dollars, { $0.period = .trip(from: Self.today, through: Self.today) }, .budgetFieldFixed("period")),
      (Self.trip, { $0.period = .monthly }, .budgetFieldFixed("period")),
      (Self.dollars, { $0.name = "" }, .budgetNameRequired),
      (Self.dollars, { $0.name = nil }, .budgetNameRequired),
      (Self.dollars, { $0.limitMinor = nil }, .budgetLimitRequired),
      (Self.dollars, { $0.limitMinor = -1 }, .negativeLimit(-1)),
      (Self.dollars, { $0.oneOffFromMinor = -1 }, .negativeLimit(-1)),
    ]
    for (id, change, expected) in cases {
      let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.update(id, today: Self.today, in: &transaction, change) }
      #expect(refused == expected)
    }
  }

  @Test func shouldRefuseEditingOrDeletingABudgetThatIsAbsentOrDeleted() async throws {
    let store = try await F.store()
    #expect(
      try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.update(Self.dollars, today: Self.today, in: &transaction) { $0.name = "X" } }
        == .budgetAbsent(Self.dollars))
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)
    _ = try await store.write { transaction in try BudgetEdits.delete(Self.dollars, in: &transaction) }
    #expect(try await F.refusal(in: store) { transaction throws(FinanceError) in try BudgetEdits.delete(Self.dollars, in: &transaction) } == .budgetAbsent(Self.dollars))
    #expect(
      try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.update(Self.dollars, today: Self.today, in: &transaction) { $0.name = "X" } }
        == .budgetAbsent(Self.dollars))
    #expect(
      try await F.refusal(in: store) { transaction throws(FinanceError) in
        _ = try BudgetEdits.create(F.monthly("Dollars", F.usd, limitMinor: 1), id: Self.dollars, today: Self.today, in: &transaction)
      } == .budgetExists(Self.dollars))
    try await Self.create(F.monthly("Dollars again", F.usd, limitMinor: 1), Self.other, in: store)
  }

  @Test func shouldStageARaiseToTheNextMonthAndApplyALoweringToThisMonthAtOnce() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)

    let raised = try await Self.update(Self.dollars, in: store) { $0.limitMinor = 40_000 }
    #expect(raised?.limitMinor == 30_000)
    #expect(raised?.stagedLimit == StagedAmount(amountMinor: 40_000, from: F.date("2026-12-01")))
    var budget = try await Self.live(Self.dollars, in: store)
    #expect(budget.limitMinor(on: Self.today) == 30_000)
    #expect(budget.limitMinor(on: F.date("2026-11-30")) == 30_000)
    #expect(budget.limitMinor(on: F.date("2026-12-01")) == 40_000)
    #expect(budget.pendingLimit(on: Self.today)?.amountMinor == 40_000)
    #expect(BudgetDraft(budget, on: Self.today).limitMinor == 40_000, "the draft shows the limit the raise will bring")

    let withdrawn = try await Self.update(Self.dollars, in: store) { $0.limitMinor = 30_000 }
    #expect(withdrawn?.limitMinor == 30_000)
    #expect(withdrawn?.stagedLimit == nil, "setting the limit in force again withdraws the raise")

    try await Self.update(Self.dollars, in: store) { $0.limitMinor = 45_000 }
    let lowered = try await Self.update(Self.dollars, in: store) { $0.limitMinor = 20_000 }
    #expect(lowered?.stagedLimit == StagedAmount(amountMinor: 20_000, from: F.date("2026-11-01")), "a lowering clears the pending raise")
    budget = try await Self.live(Self.dollars, in: store)
    #expect(budget.limitMinor(on: F.date("2026-11-01")) == 20_000, "a lowering applies to the whole month at once")
    #expect(budget.limitMinor(on: F.date("2026-12-01")) == 20_000)
    #expect(budget.limitMinor(on: F.date("2026-10-31")) == 30_000, "last month keeps the limit it closes with")
    #expect(budget.pendingLimit(on: Self.today) == nil)
    let period = try #require(budget.period(containing: Self.today))
    #expect(budget.limitMinor(for: period) == 20_000)
  }

  @Test func shouldApplyAStagedRaiseOnItsDayWithoutAnyWrite() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)
    let staged = try #require(try await Self.update(Self.dollars, in: store) { $0.limitMinor = 40_000 })
    let december = F.date("2026-12-05")

    var budget = try await Self.live(Self.dollars, in: store)
    #expect(budget.limitMinor(on: december) == 40_000)
    #expect(budget.pendingLimit(on: december) == nil)
    #expect(try await F.record(Self.dollars, in: store) == staged, "the raise took effect without a write")

    let lowered = try await Self.update(Self.dollars, on: december, in: store) { $0.limitMinor = 35_000 }
    #expect(lowered?.limitMinor == 30_000)
    #expect(lowered?.stagedLimit == StagedAmount(amountMinor: 35_000, from: F.date("2026-12-01")))
    budget = try await Self.live(Self.dollars, in: store)
    #expect(budget.limitMinor(on: F.date("2026-11-30")) == 30_000)
    #expect(budget.limitMinor(on: december) == 35_000)

    let raisedAgain = try await F.refusal(in: store) { transaction throws(FinanceError) in
      _ = try BudgetEdits.update(Self.dollars, today: december, in: &transaction) { $0.limitMinor = 50_000 }
    }
    #expect(raisedAgain == .limitChangedThisMonth, "a raise after this month's lowering would rewrite last month's limit")
    let raisedInJanuary = try await Self.update(Self.dollars, on: F.date("2027-01-02"), in: store) { $0.limitMinor = 50_000 }
    #expect(raisedInJanuary?.stagedLimit == StagedAmount(amountMinor: 50_000, from: F.date("2027-02-01")))
    #expect(try await Self.live(Self.dollars, in: store).limitMinor(on: F.date("2026-12-31")) == 35_000)
  }

  @Test func shouldRefuseARaiseThatWouldLiftLastMonthsLimitBeforeItCloses() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)
    try await Self.update(Self.dollars, on: F.date("2026-11-30"), in: store) { $0.limitMinor = 40_000 }
    let december = F.date("2026-12-01")
    let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in
      _ = try BudgetEdits.update(Self.dollars, today: december, in: &transaction) { $0.limitMinor = 90_000 }
    }
    #expect(refused == .limitChangedThisMonth)
    let budget = try await Self.live(Self.dollars, in: store)
    #expect(budget.limitMinor(on: F.date("2026-11-30")) == 30_000, "November is still measured against its own limit")
    #expect(budget.limitMinor(on: december) == 40_000)
    let lowered = try await Self.update(Self.dollars, on: december, in: store) { $0.limitMinor = 35_000 }
    #expect(lowered?.limitMinor == 30_000, "a lowering keeps November's limit")
    #expect(lowered?.stagedLimit == StagedAmount(amountMinor: 35_000, from: december))
    let restored = try await Self.update(Self.dollars, on: december, in: store) { $0.limitMinor = 30_000 }
    #expect(restored?.limitMinor == 30_000)
    #expect(restored?.stagedLimit == nil)
    let raised = try await Self.update(Self.dollars, on: december, in: store) { $0.limitMinor = 90_000 }
    #expect(raised?.stagedLimit == StagedAmount(amountMinor: 90_000, from: F.date("2027-01-01")), "once this month's limit is last month's again, a raise waits")
  }

  @Test func shouldRefuseATripStartingMoreThanThreeDaysAgo() async throws {
    let store = try await F.store()
    let tooEarly = F.trip("Late entry", F.eur, limitMinor: 1, from: "2026-11-17", through: "2026-11-30")
    let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.create(tooEarly, id: Self.trip, today: Self.today, in: &transaction) }
    #expect(refused == .tripStartTooEarly(earliest: F.date("2026-11-18")))
    try await Self.create(F.trip("Weekend", F.eur, limitMinor: 1, from: "2026-11-18", through: "2026-11-19"), Self.trip, in: store)
    try await Self.create(F.trip("Later", F.eur, limitMinor: 1, from: "2026-12-10", through: "2026-12-12"), Self.other, in: store)
    let moved = try await F.refusal(in: store) { transaction throws(FinanceError) in
      _ = try BudgetEdits.update(Self.other, today: Self.today, in: &transaction) { $0.period = .trip(from: F.date("2026-11-17"), through: F.date("2026-12-12")) }
    }
    #expect(moved == .tripStartTooEarly(earliest: F.date("2026-11-18")))
    let earlier = try await Self.update(Self.other, in: store) { $0.period = .trip(from: F.date("2026-11-21"), through: F.date("2026-12-12")) }
    #expect(earlier?.period == .trip(from: F.date("2026-11-21"), through: F.date("2026-12-12")))
    let longer = try await Self.update(Self.trip, in: store) { $0.period = .trip(from: F.date("2026-11-18"), through: F.date("2026-11-20")) }
    #expect(longer?.period == .trip(from: F.date("2026-11-18"), through: F.date("2026-11-20")), "a started trip keeps its start and can grow")
  }

  @Test func shouldLockATripsLimitAgainstRaisesFromItsFirstDay() async throws {
    let store = try await F.store()
    try await Self.create(F.trip("Lisbon", F.eur, limitMinor: 100_000, from: "2026-11-25", through: "2026-12-05"), Self.trip, in: store)
    try await Self.create(F.trip("Rome", F.eur, limitMinor: 1, from: "2026-12-10", through: "2026-12-12"), Self.other, in: store)

    let raised = try await Self.update(Self.trip, in: store) { $0.limitMinor = 120_000 }
    #expect(raised?.limitMinor == 120_000, "before the trip a raise applies at once")
    #expect(raised?.stagedLimit == nil)
    let started = F.date("2026-11-25")
    let refusals: [(LocalDate, @Sendable (inout BudgetDraft) -> Void, FinanceError)] = [
      (started, { $0.limitMinor = 120_001 }, .tripLimitLocked),
      (F.date("2026-12-06"), { $0.limitMinor = 130_000 }, .tripLimitLocked),
      (F.date("2026-11-26"), { $0.period = .trip(from: F.date("2026-11-27"), through: F.date("2026-12-05")) }, .tripStartFixed),
      (Self.today, { $0.period = .trip(from: F.date("2026-11-30"), through: F.date("2026-11-29")) }, .invalidTripDates),
      (Self.today, { $0.period = .trip(from: F.date("2026-11-25"), through: F.date("2026-12-10")) }, .tripsOverlap(Self.other)),
      (
        Self.today,
        {
          $0.period = .trip(from: F.date("2026-11-21"), through: F.date("2026-12-05"))
          $0.limitMinor = 130_000
        }, .tripLimitLocked
      ),
    ]
    for (day, change, expected) in refusals {
      let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in _ = try BudgetEdits.update(Self.trip, today: day, in: &transaction, change) }
      #expect(refused == expected, "\(day)")
    }
    let lowered = try await Self.update(Self.trip, on: F.date("2026-11-26"), in: store) { $0.limitMinor = 90_000 }
    #expect(lowered?.limitMinor == 90_000)
    let extended = try await Self.update(Self.trip, on: F.date("2026-11-26"), in: store) { $0.period = .trip(from: started, through: F.date("2026-12-09")) }
    #expect(extended?.period == .trip(from: started, through: F.date("2026-12-09")))
    let moved = try await Self.update(Self.other, in: store) { $0.period = .trip(from: F.date("2026-12-11"), through: F.date("2026-12-12")) }
    #expect(moved != nil, "a trip not yet started can move its first day")
    let budget = try await Self.live(Self.trip, in: store)
    #expect(budget.period(containing: F.date("2026-11-24")) == nil)
    #expect(budget.period(containing: started)?.span == DateSpan(start: started, end: F.date("2026-12-09")))
  }

  @Test func shouldStageALowerOneOffThresholdAndApplyAHigherOneAtOnce() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)

    let first = try await Self.update(Self.dollars, in: store) { $0.oneOffFromMinor = 10_000 }
    #expect(first?.oneOffFromMinor == nil)
    #expect(first?.stagedOneOff == StagedAmount(amountMinor: 10_000, from: F.date("2026-12-01")), "a threshold in place of the automatic one waits a month")
    let december = F.date("2026-12-02")
    #expect(try await Self.live(Self.dollars, in: store).oneOffFromMinor(on: december) == 10_000)

    let lowered = try await Self.update(Self.dollars, on: december, in: store) { $0.oneOffFromMinor = 8_000 }
    #expect(lowered?.oneOffFromMinor == 10_000)
    #expect(lowered?.stagedOneOff == StagedAmount(amountMinor: 8_000, from: F.date("2027-01-01")))
    let budget = try await Self.live(Self.dollars, in: store)
    #expect(budget.oneOffFromMinor(on: december) == 10_000)
    #expect(budget.pendingOneOff(on: december)?.amountMinor == 8_000)

    let raised = try await Self.update(Self.dollars, on: december, in: store) { $0.oneOffFromMinor = 15_000 }
    #expect(raised?.oneOffFromMinor == 15_000)
    #expect(raised?.stagedOneOff == nil, "a raise applies at once and drops the pending lowering")

    let cleared = try await Self.update(Self.dollars, on: december, in: store) { $0.oneOffFromMinor = nil }
    #expect(cleared?.oneOffFromMinor == nil)
    #expect(cleared?.stagedOneOff == nil)
  }

  @Test func shouldWriteNothingWhenAnEditMovesNothing() async throws {
    let store = try await F.store()
    try await Self.create(F.monthly("Dollars", F.usd, limitMinor: 30_000), Self.dollars, in: store)
    #expect(try await Self.update(Self.dollars, in: store) { _ in } == nil)
    #expect(try await Self.update(Self.dollars, in: store) { $0.name = "  Dollars " } == nil)
    #expect(try await Self.update(HomeBudget.id, in: store) { $0.limitMinor = 50_000 } == nil, "Home's draft shows the account's limit it falls back to")
    let renamed = try await Self.update(Self.dollars, in: store) { $0.name = "USD" }
    #expect(renamed?.name == "USD")
  }

  @Test func shouldFallBackToTheAccountsMonthlyBudgetUntilHomesLimitIsWritten() async throws {
    let store = try await F.store()
    _ = try await store.write { transaction in try HomeBudget.ensure(on: Self.today, in: &transaction) }
    #expect(try await F.budgets(in: store).home?.limitMinor(on: Self.today) == 50_000)

    _ = try await store.write { transaction in
      try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { $0.monthlyBudget = MoneyAmount(amountMinor: 70_000, currency: F.usd) }
    }
    #expect(try await F.budgets(in: store).home?.limitMinor(on: Self.today) == nil, "an account budget in another currency is not Home's")

    _ = try await store.write { transaction in
      try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { $0.monthlyBudget = MoneyAmount(amountMinor: 60_000, currency: F.eur) }
    }
    let lowered = try await Self.update(HomeBudget.id, in: store) { $0.limitMinor = 45_000 }
    #expect(lowered?.limitMinor == 60_000)
    #expect(lowered?.stagedLimit == StagedAmount(amountMinor: 45_000, from: F.date("2026-11-01")))
    _ = try await store.write { transaction in
      try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { $0.monthlyBudget = MoneyAmount(amountMinor: 10, currency: F.eur) }
    }
    let home = try #require(try await F.budgets(in: store).home)
    #expect(home.limitMinor(on: Self.today) == 45_000, "once written, Home's limit no longer follows the account")
    #expect(home.limitMinor(on: F.date("2026-10-31")) == 60_000)
    let settings = try await store.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction) }.entry?.record
    #expect(settings?.monthlyBudget?.amountMinor == 10, "Home's limit is never written back to the account")
  }

  @Test func shouldEnsureHomeOnceAndLeaveItWhenTheDefaultCurrencyMoves() async throws {
    let bare = try MemoirStore.openInMemory(.main)
    #expect(try await bare.write { transaction in try HomeBudget.ensure(on: Self.today, in: &transaction) } == .waitingForSettings)
    #expect(try await F.record(HomeBudget.id, in: bare) == nil)

    let store = try await F.store()
    let home = BudgetRecord(id: HomeBudget.id, currency: F.eur, period: .monthly, createdOn: Self.today)
    #expect(try await store.write { transaction in try HomeBudget.ensure(on: Self.today, in: &transaction) } == .created(home))
    let later = F.date("2026-12-01")
    let logged = try await store.pendingChanges(limit: Int.max).count
    #expect(try await store.write { transaction in try HomeBudget.ensure(on: later, in: &transaction) } == .present(home))
    #expect(try await store.pendingChanges(limit: Int.max).count == logged, "a second ensure writes nothing")

    var moved = try #require(try await store.read { transaction in try AccountSettingsRecord.read(key: .accountSettings, in: transaction) }.entry?.record)
    try moved.changeDefaultCurrency(to: F.gbp)
    let changed = moved
    _ = try await store.write { transaction in try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { $0 = changed } }
    #expect(try await store.write { transaction in try HomeBudget.ensure(on: later, in: &transaction) } == .currencyDiffers(home, account: F.gbp))
    let budgets = try await F.budgets(in: store)
    #expect(budgets.home?.currency == F.eur)
    #expect(budgets.homeCurrency == F.eur)
    #expect(budgets.home?.limitMinor(on: later) == nil, "the cleared account budget leaves Home without a limit")
  }

  @Test func shouldRefuseAMonthlyBudgetInTheHomeCurrencyEvenBeforeHomeIsWritten() async throws {
    let store = try await F.store()
    #expect(try await F.record(HomeBudget.id, in: store) == nil)
    let refused = try await F.refusal(in: store) { transaction throws(FinanceError) in
      _ = try BudgetEdits.create(F.monthly("Euros", F.eur, limitMinor: 1), id: Self.other, today: Self.today, in: &transaction)
    }
    #expect(refused == .currencyTaken(F.eur))
  }
}
