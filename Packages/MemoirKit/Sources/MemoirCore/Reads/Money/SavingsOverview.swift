import Foundation
import ShadowCore
import ShadowStore

extension BudgetPeriodStanding {
  /// What a monthly budget's month is measured against for its deposit: the limit, or the typical month times `SavingsRules.referenceThousandths`
  /// (halves up) when that is lower. Nil for a trip, a budget without a limit and a calibrating one, which deposit nothing.
  public var depositReferenceMinor: Int64? {
    guard budget.record.period == .monthly else { return nil }
    return Self.depositReference(limitMinor: limitMinor, history: history)
  }

  static func depositReference(limitMinor: Int64?, history: BudgetHistory?) -> Int64? {
    guard let limit = limitMinor, case .known(let typical, _)? = history?.typical else { return nil }
    return min(limit, Int64(clamping: Exact.roundHalfUp(Int128(typical) * Int128(SavingsRules.referenceThousandths), 1000)))
  }

  /// What the month would deposit if it ended as it is going: the reference less the projected spending, never below zero; nil without a reference.
  public var projectedDepositMinor: Int64? {
    depositReferenceMinor.map { max(0, Int64(clamping: Int128($0) - Int128(projectedMinor ?? spend.spentMinor))) }
  }
}

/// The current month's monthly budgets, on pace to deposit this much at their closes, in the home currency: kept apart from savings, since nothing is
/// deposited until the month closes. A foreign budget converts at its currency's newest recorded rate on or before today.
public struct SavingsLiveMonth: Sendable, Hashable {
  public let projectedMinor: Int64
  /// The budgets whose projection is in `projectedMinor`.
  public let budgets: [UUID]
  public let pending: PendingConversions

  static func make(_ standings: BudgetStandings, converter: BudgetConverter) -> SavingsLiveMonth? {
    var total = Int128(0)
    var budgets = [UUID]()
    var awaiting = 0
    var unconvertible = 0
    var currencies = Set<String>()
    for standing in standings.budgets {
      guard case .current = standing.phase, let projected = standing.projectedDepositMinor else { continue }
      let currency = standing.budget.currency
      let rate = currency == converter.home ? nil : converter.latestRate(of: currency, onOrBefore: standings.today)?.rate
      switch HomeConverter.convert(MoneyAmount(amountMinor: projected, currency: currency), home: converter.home, rate: rate) {
      case .converted(let minor):
        total += Int128(minor)
        budgets.append(standing.id)
      case .awaitingRate:
        awaiting += 1
        currencies.insert(currency.code)
      case .unconvertible:
        unconvertible += 1
      }
    }
    guard !budgets.isEmpty || awaiting + unconvertible > 0 else { return nil }
    return SavingsLiveMonth(
      projectedMinor: Int64(clamping: total), budgets: budgets,
      pending: PendingConversions(awaitingRate: awaiting, unconvertible: unconvertible, currencies: currencies.sorted().compactMap(CurrencyCode.init)))
  }
}

/// Savings and the goals they fill, on the account's day.
public struct SavingsOverview: Sendable, Hashable {
  public let today: LocalDate
  public let home: CurrencyCode
  public let balance: SavingsBalance
  /// Deposits by month, oldest first.
  public let history: [SavingsMonth]
  public let pace: SavingsPace
  public let allocation: SavingsAllocation
  /// One per active goal, in fill order.
  public let forecasts: [GoalForecast]
  public let liveMonth: SavingsLiveMonth?
  /// Whether each goal not deleted earns its milestones and purchase reward, by goal.
  public let rewards: [UUID: GoalRewardEligibility]
  public let unreadableGoals: Int

  public func forecast(of goal: UUID) -> GoalForecast? {
    forecasts.first { $0.goal == goal }
  }

  public func isRewardEligible(_ goal: UUID) -> Bool {
    rewards[goal]?.isEligible ?? false
  }

  /// Nil until the vault has its settings, which name the home currency.
  public static func make(_ book: SavingsBook, today: LocalDate) throws(FinanceError) -> SavingsOverview? {
    guard let converter = book.converter, let standings = try BudgetStandings.make(book.budgets, today: today) else { return nil }
    guard let currentMonth = LocalDate(year: today.year, month: today.month, day: 1) else { throw .dateOutOfRange }
    let home = converter.home
    let homeBudget = book.budgets.liveBudgets(today: today).first(where: \.isHome)
    let balance = SavingsBalance.make(book, converter: converter, today: today)
    let history = SavingsMonth.history(book, home: home)
    let pace = SavingsPace.make(book, history: history, today: today)
    let withdrawals = book.withdrawals(converter: converter)
    let allocation = SavingsAllocation.make(balanceMinor: balance.balanceMinor, goals: book.goals, home: home, withdrawals: withdrawals)
    let inputs = GoalForecast.Inputs(
      today: today, currentMonth: currentMonth, pace: pace, allocation: allocation,
      undelayed: undelayed(book, balance: balance, withdrawals: withdrawals, currentMonth: currentMonth, home: home),
      levers: levers(book, converter: converter, currentMonth: currentMonth))
    return SavingsOverview(
      today: today, home: home, balance: balance, history: history, pace: pace, allocation: allocation, forecasts: GoalForecast.make(inputs),
      liveMonth: SavingsLiveMonth.make(standings, converter: converter),
      rewards: Dictionary(book.goals.map { ($0.id, GoalRewardEligibility.of($0, home: homeBudget, converter: converter)) }) { first, _ in first },
      unreadableGoals: book.unreadableGoals)
  }

  /// This month's withdrawals that bought no goal (none named, or one deleted or abandoned), put back: the allocation as it would stand without them.
  private static func undelayed(
    _ book: SavingsBook, balance: SavingsBalance, withdrawals: [SavingsWithdrawal], currentMonth: LocalDate, home: CurrencyCode
  ) -> (allocation: SavingsAllocation, cause: UUID, withdrawnMinor: Int64)? {
    let buying = Set(book.goals.filter { $0.state == .known(.active) || $0.state == .known(.bought) }.map(\.id))
    let general = withdrawals.filter { withdrawal in
      withdrawal.amount.minor != nil && withdrawal.occurredOn.monthIndex == currentMonth.monthIndex
        && !(withdrawal.goal.map(buying.contains) ?? false)
    }
    let cause = general.max { first, second in
      let (a, b) = (first.amount.minor ?? 0, second.amount.minor ?? 0)
      if a != b { return a < b }
      if first.occurredOn != second.occurredOn { return first.occurredOn < second.occurredOn }
      return first.expense.uuidString < second.expense.uuidString
    }
    guard let cause else { return nil }
    let total = general.reduce(Int128(0)) { $0 + Int128($1.amount.minor ?? 0) }
    let without = Set(general.map(\.expense))
    let allocation = SavingsAllocation.make(
      balanceMinor: Int64(clamping: Int128(balance.balanceMinor) + total), goals: book.goals, home: home, withdrawals: withdrawals.filter { !without.contains($0.expense) })
    return (allocation, cause.expense, Int64(clamping: total))
  }

  /// The categories a lever may name, by key: neither essential nor uncategorised, with the saving `SavingsRules.leverThousandths` less of their mean
  /// monthly spending would bring, rounded down. Spending is each expense without its savings part, in home as every home total converts it; the months
  /// with none count as zero.
  private static func levers(_ book: SavingsBook, converter: BudgetConverter, currentMonth: LocalDate) -> [(category: CategoryKey, savingMinor: Int64)] {
    guard let from = currentMonth.adding(months: -SavingsRules.leverMonths) else { return [] }
    var totals = [CategoryKey: Int128]()
    for expense in book.budgets.assignments.expenses where expense.occurredOn >= from && expense.occurredOn < currentMonth {
      guard expense.category != MoneyBook.uncategorised, !book.essentials.isEssential(expense.category),
        let minor = converter.homeConverter.homeAmount(of: expense.budgetPortion).minor
      else { continue }
      totals[expense.category, default: 0] += Int128(minor)
    }
    return totals.sorted { $0.key.key < $1.key.key }.compactMap { category, total in
      let mean = Exact.roundHalfUp(total, Int128(SavingsRules.leverMonths))
      let saving = Int64(clamping: Exact.floorDivide(mean * Int128(SavingsRules.leverThousandths), 1000))
      return saving > 0 ? (category, saving) : nil
    }
  }
}

public enum SavingsReads {
  public static func overview(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> SavingsOverview? {
    try await readCall { () async throws(StoreError) in
      try await stores.main.read { transaction in try build(try SavingsBook.load(from: transaction), today: today) }
    }
  }

  public static func observeOverview(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<SavingsOverview?, any Error> {
    ReadObservation.observe(ObservedRead(stores.main) { transaction in try SavingsBook.load(from: transaction) }) { book in try build(book, today: today) }
  }

  private static func build(_ book: SavingsBook, today: LocalDate) throws(MemoirReadError) -> SavingsOverview? {
    do throws(FinanceError) {
      return try SavingsOverview.make(book, today: today)
    } catch {
      throw .finance(error)
    }
  }
}
