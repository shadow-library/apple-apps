import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir demo money", TestTimeLimit.standard)
struct DemoMoneyTests {
  private static let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
  private static let now = Date(timeIntervalSince1970: 1_795_000_000)
  private static let euro = CurrencyCode("EUR")!

  private struct Seeded {
    let stores: MemoirStores
    let today: LocalDate
  }

  private static func seeded(now: Date = now, currency: CurrencyCode = euro) async throws -> Seeded {
    let reconciler = try MemoirReconciler(appVersion: "1", now: { now }, deviceZone: { zone })
    let stores = try MemoirStores.openInMemory(wallClock: { now }, projection: reconciler)
    try await MemoirDemo.seed(stores, now: now, zone: zone, currency: currency)
    try await reconciler.refresh(stores.main)
    return Seeded(stores: stores, today: try IssueClock(timeZone: zone).localDate(at: Int64(now.timeIntervalSince1970 * 1000)))
  }

  private static func outcomes(_ stores: MemoirStores) async throws -> [UUID: ReplayOutcome] {
    Replay.run(try await stores.main.read { transaction in try Replay.commands(in: transaction) }).outcomes
  }

  @Test("should replay every seeded command as applied, with no refusal and no halt")
  func shouldReplayEveryCommandApplied() async throws {
    let seeded = try await Self.seeded()
    let outcomes = try await Self.outcomes(seeded.stores)

    #expect(outcomes.count > 150)
    #expect(outcomes.values.allSatisfy { $0 == .applied })
    #expect(Replay.run(try await seeded.stores.main.read { transaction in try Replay.commands(in: transaction) }).halt == nil)
  }

  @Test("should show Home on track with its closed months, a trip in another currency and no pending conversion")
  func shouldShowTheBudgets() async throws {
    let seeded = try await Self.seeded()
    let standings = try #require(try await MoneyReads.budgetStandings(in: seeded.stores, today: seeded.today))

    let home = try #require(standings.homeBudget)
    #expect(home.limitMinor == DemoMoney.homeLimitMinor)
    #expect(home.pace == .onTrack)
    guard case .known = home.history?.typical else {
      Issue.record("Home's typical month is known")
      return
    }
    let trip = try #require(standings.standing(of: DemoMoney.tripID))
    #expect(trip.budget.currency != Self.euro)
    #expect(trip.spend.spentMinor == 640 + 1_850 + 1_490 + 920 + 2_130)
    #expect(trip.spend.pending == .none)
    #expect(trip.pace == .onTrack)
    #expect(standings.consolidated.spend.pending == .none && standings.consolidated.limitsPending == .none)
  }

  @Test("should keep three deposits after two calibration months, the first closes depositing nothing")
  func shouldDepositAfterCalibration() async throws {
    let seeded = try await Self.seeded()
    let book = try await seeded.stores.main.read { transaction in try BudgetBook.load(from: transaction) }
    let deposits = book.deposits.sorted { $0.key.periodStart < $1.key.periodStart }.map(\.value)

    #expect(deposits.count == 5)
    #expect(deposits.map { $0.amountMinor > 0 } == [false, false, true, true, true])
    #expect(deposits.allSatisfy { $0.limitMinor == DemoMoney.homeLimitMinor && $0.currency == Self.euro })
    let overview = try #require(try await SavingsReads.overview(in: seeded.stores, today: seeded.today))
    #expect(overview.balance.balanceMinor == deposits.reduce(0) { $0 + $1.amountMinor })
    #expect(overview.pace.perMonthMinor.map { $0 > 0 } == true)
  }

  @Test("should give the hero a money streak, a saving streak and the closes the replay took")
  func shouldFillTheMoneyGame() async throws {
    let seeded = try await Self.seeded()
    let standing = try await seeded.stores.main.load(MoneyGameStanding.self, MoneyGameQuery())

    #expect(standing.weekStreak > 0)
    #expect(standing.savingStreak == 3)
    #expect(standing.recentCloses.count == 5)
    #expect(standing.recentCloses.filter(\.deposited).count == 3)
    #expect(standing.debuff == nil)
  }

  @Test("should forecast the goal as arriving on time and earn rewards for it")
  func shouldForecastTheGoal() async throws {
    let seeded = try await Self.seeded()
    let overview = try #require(try await SavingsReads.overview(in: seeded.stores, today: seeded.today))
    let forecast = try #require(overview.forecast(of: DemoMoney.goalID))

    #expect(overview.isRewardEligible(DemoMoney.goalID))
    guard case .aheadOfTarget(let eta, let target) = forecast.state else {
      Issue.record("the goal is ahead of its target, not \(forecast.state)")
      return
    }
    #expect(eta < target)
    #expect(forecast.shareMinor > 0 && forecast.remainingMinor > 0)
  }

  @Test("should record the partial refund on the expense it returned part of")
  func shouldRefundInPart() async throws {
    let seeded = try await Self.seeded()
    let expense = try #require(
      try await seeded.stores.main.read { transaction in try MoneyBook.load(from: transaction) }.expenses.first { $0.merchant == "Market Hall" && $0.amountMinor == 4_235 - 650 })
    let history = try await MoneyReads.history(of: expense.id, in: seeded.stores)

    #expect(history.entries.contains { isRefund($0.action) })
  }

  private func isRefund(_ action: ExpenseHistoryAction) -> Bool {
    guard case .refunded(let from, let to, _) = action else { return false }
    return from == 4_235 && to == 3_585
  }

  @Test("should seed the same money whichever time it is run twice")
  func shouldBeDeterministic() async throws {
    let first = try await Self.seeded()
    let second = try await Self.seeded()

    func summary(_ seeded: Seeded) async throws -> [String] {
      let book = try await seeded.stores.main.read { transaction in try BudgetBook.load(from: transaction) }
      let deposits = book.deposits.sorted { $0.key.periodStart < $1.key.periodStart }.map { "\($0.key.periodStart) \($0.value.amountMinor) \($0.value.spentMinor)" }
      let expenses = book.assignments.expenses.sorted { $0.id.uuidString < $1.id.uuidString }.map { "\($0.id) \($0.occurredOn) \($0.amountMinor) \($0.currency)" }
      return deposits + expenses
    }

    #expect(try await summary(first) == summary(second))
  }

  private static func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
  }

  private static func expectDeposits(of seeded: Seeded) async throws {
    let book = try await seeded.stores.main.read { transaction in try BudgetBook.load(from: transaction) }
    let home = try #require(book.liveBudgets(today: seeded.today).first { $0.isHome })
    let converter = try #require(book.converter)
    let periods = book.deposits.keys.map(\.periodStart).sorted()

    for period in periods.dropFirst(2) {
      let deposit = try #require(book.deposits[MoneyCloseKey(budget: HomeBudget.id, periodStart: period)])
      let span = try #require(DateSpan.month(of: period))
      let history = try #require(book.history(of: home, before: BudgetPeriod(span: span), today: seeded.today))
      guard case .known(let typical, _) = history.typical else {
        Issue.record("the typical month is known")
        return
      }
      let reference = min(DemoMoney.homeLimitMinor, Int64(Exact.roundHalfUp(Int128(typical) * Int128(SavingsRules.referenceThousandths), 1000)))
      let logged = book.expenses(of: HomeBudget.id, in: BudgetPeriod(span: span))
      #expect(deposit.spentMinor == BudgetSpend.tally(logged) { converter.amount(of: $0, in: home.currency) }.spentMinor)
      #expect(deposit.medianExpenseMinor == BudgetHistory.median(logged.map(\.amountMinor).filter { $0 > 0 }))
      #expect(deposit.amountMinor == max(0, reference - deposit.spentMinor))
    }
  }

  @Test("should agree with the savings rules on every seeded deposit, whichever day and home currency the demo opens in")
  func shouldDepositWhatTheRulesSay() async throws {
    let days = [(2026, 11, 18), (2026, 12, 29), (2027, 1, 1), (2027, 1, 3), (2027, 2, 2), (2027, 2, 28), (2027, 3, 1), (2028, 2, 29), (2027, 5, 31), (2027, 7, 15)]
    for (year, month, day) in days {
      for code in ["EUR", "JPY", "USD", "GBP"] {
        try await Self.expectDeposits(of: try await Self.seeded(now: try Self.date(year, month, day), currency: try #require(CurrencyCode(code))))
      }
    }
  }

  @Test("should replay cleanly and show three deposits and a forecast whichever day the demo opens", arguments: Array(0..<45))
  func shouldSeedWhicheverDay(offset: Int) async throws {
    let now = Self.now.addingTimeInterval(Double(offset) * 86_400 - 20 * 86_400)
    let seeded = try await Self.seeded(now: now)
    let outcomes = try await Self.outcomes(seeded.stores)
    let book = try await seeded.stores.main.read { transaction in try BudgetBook.load(from: transaction) }
    let overview = try #require(try await SavingsReads.overview(in: seeded.stores, today: seeded.today))

    #expect(outcomes.values.allSatisfy { $0 == .applied })
    #expect(book.deposits.values.filter { $0.amountMinor > 0 }.count == 3)
    #expect(overview.forecast(of: DemoMoney.goalID) != nil)
    #expect(overview.pace.perMonthMinor != nil)
  }

  @Test("should convert the trip into a home currency other than the euro")
  func shouldSeedAnotherHomeCurrency() async throws {
    for code in ["USD", "GBP", "JPY"] {
      let seeded = try await Self.seeded(currency: try #require(CurrencyCode(code)))
      let standings = try #require(try await MoneyReads.budgetStandings(in: seeded.stores, today: seeded.today))

      #expect(standings.consolidated.spend.pending == .none && standings.consolidated.limitsPending == .none)
      #expect(standings.standing(of: DemoMoney.tripID)?.budget.currency.code != code)
    }
  }
}
