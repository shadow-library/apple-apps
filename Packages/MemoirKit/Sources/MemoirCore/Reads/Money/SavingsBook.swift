import Foundation
import ShadowCore
import ShadowStore

/// What savings and goals are computed from, read in one transaction of the main store: the budget book (expenses, rates, deposits, closes), every
/// readable budget record with the deleted ones, whose deposits still count, the goals not deleted, and which categories are essential.
public struct SavingsBook: Sendable, Equatable {
  public let budgets: BudgetBook
  public let budgetRecords: [BudgetRecord]
  public let goals: [SavingsGoalRecord]
  public let unreadableGoals: Int
  public let essentials: CategoryEssentials

  public init(budgets: BudgetBook, budgetRecords: [BudgetRecord], goals: [SavingsGoalRecord], unreadableGoals: Int = 0, essentials: CategoryEssentials) {
    self.budgets = budgets
    self.budgetRecords = budgetRecords
    self.goals = goals
    self.unreadableGoals = unreadableGoals
    self.essentials = essentials
  }

  public static func load(from transaction: ReadTransaction) throws(MemoirReadError) -> SavingsBook {
    let budgets = try BudgetBook.load(from: transaction)
    do throws(StoreError) {
      let records = try BudgetRecord.listing(in: transaction)
      let goals = try SavingsGoalRecord.listing(in: transaction)
      let categories = try ExpenseCategoryRecord.listing(in: transaction)
      return SavingsBook(
        budgets: budgets, budgetRecords: records.entries.map(\.record), goals: goals.entries.filter { !$0.isRemoved }.map(\.record), unreadableGoals: goals.unreadable,
        essentials: CategoryEssentials(records: categories.entries.map(\.record)))
    } catch {
      throw MemoirReadError(error)
    }
  }

  /// Into the account's default currency, the home currency of savings; nil before the vault has settings.
  public var converter: BudgetConverter? { budgets.converter }

  /// Every live expense that drew on savings, the part it drew converted into home on its own, exactly as `HomeConverter` converts an amount.
  func withdrawals(converter: BudgetConverter) -> [SavingsWithdrawal] {
    budgets.assignments.expenses.filter { $0.savingsPortionMinor > 0 }.map { expense in
      var portion = expense
      portion.amountMinor = expense.savingsPortionMinor
      return SavingsWithdrawal(
        expense: expense.id, occurredOn: expense.occurredOn, goal: expense.goal, currency: expense.currency, amount: converter.homeConverter.homeAmount(of: portion))
    }
  }

  func activeGoals(home: CurrencyCode) -> [SavingsGoalRecord] {
    goals.filter { $0.state == .known(.active) && $0.currency == home }.sorted(by: SavingsGoalRecord.precedes)
  }
}

extension SavingsGoalRecord {
  /// Fill order: by rank, two goals given the same rank on two devices by id.
  static func precedes(_ first: SavingsGoalRecord, _ second: SavingsGoalRecord) -> Bool {
    first.rank != second.rank ? first.rank < second.rank : first.id.uuidString < second.id.uuidString
  }
}

/// The part of one expense paid from savings, in the home currency.
public struct SavingsWithdrawal: Sendable, Hashable {
  public let expense: UUID
  public let occurredOn: LocalDate
  public let goal: UUID?
  public let currency: CurrencyCode
  public let amount: HomeAmount
}

/// How far below zero savings may go: the limit Home holds for the current month, in the home currency; none while Home has no limit or its limit cannot
/// convert, and none while a foreign Home waits for its rate.
public enum BorrowingLimit: Sendable, Hashable {
  case noLimit
  case limit(Int64)
  case awaitingRate

  public var minor: Int64 {
    guard case .limit(let minor) = self else { return 0 }
    return minor
  }
}

public enum SavingsStanding: Sendable, Hashable {
  case saving
  /// Below zero: later deposits repay this before any goal fills.
  case repaying(owedMinor: Int64)
}

/// Savings in the home currency: every deposit in the home currency less every withdrawal that converted. A withdrawal still waiting for a rate, or one that
/// cannot convert, is counted apart and never in the balance; a deposit in another currency (written while two devices disagreed on the home currency) is
/// set aside, never converted, since nothing records a rate for it. Two devices can each draw within what is available and leave the balance below the
/// floor once both arrive: it is shown as it is and nothing more can be drawn until deposits bring it back.
public struct SavingsBalance: Sendable, Hashable {
  public let home: CurrencyCode
  public let depositedMinor: Int64
  public let withdrawnMinor: Int64
  public let balanceMinor: Int64
  public let borrowing: BorrowingLimit
  /// The balance less the floor (`-borrowing.minor`), never below zero.
  public let availableMinor: Int64
  public let standing: SavingsStanding
  public let pendingWithdrawals: PendingConversions
  public let depositsInOtherCurrencies: Int

  /// The floor: savings never go below this through a withdrawal checked when written.
  public var floorMinor: Int64 { -borrowing.minor }

  /// The balance less the floor, below zero once draws from two devices went past it.
  let headroom: Int128

  static func make(_ book: SavingsBook, converter: BudgetConverter, today: LocalDate, excluding expense: UUID? = nil) -> SavingsBalance {
    let home = converter.home
    var deposited = Int128(0)
    var otherCurrencies = 0
    for deposit in book.budgets.deposits.values {
      guard deposit.currency == home else {
        otherCurrencies += 1
        continue
      }
      deposited += Int128(max(0, deposit.amountMinor))
    }
    var withdrawn = Int128(0)
    var awaiting = 0
    var unconvertible = 0
    var currencies = Set<String>()
    for withdrawal in book.withdrawals(converter: converter) where withdrawal.expense != expense {
      switch withdrawal.amount {
      case .converted(let minor): withdrawn += Int128(minor)
      case .awaitingRate:
        awaiting += 1
        currencies.insert(withdrawal.currency.code)
      case .unconvertible: unconvertible += 1
      }
    }
    let borrowing = Self.borrowing(book, converter: converter, today: today)
    let balance = deposited - withdrawn
    let headroom = balance + Int128(borrowing.minor)
    return SavingsBalance(
      home: home, depositedMinor: Int64(clamping: deposited), withdrawnMinor: Int64(clamping: withdrawn), balanceMinor: Int64(clamping: balance), borrowing: borrowing,
      availableMinor: Int64(clamping: max(0, headroom)), standing: balance < 0 ? .repaying(owedMinor: Int64(clamping: -balance)) : .saving,
      pendingWithdrawals: PendingConversions(awaitingRate: awaiting, unconvertible: unconvertible, currencies: currencies.sorted().compactMap(CurrencyCode.init)),
      depositsInOtherCurrencies: otherCurrencies, headroom: headroom)
  }

  private static func borrowing(_ book: SavingsBook, converter: BudgetConverter, today: LocalDate) -> BorrowingLimit {
    guard let home = book.budgets.liveBudgets(today: today).first(where: \.isHome), let month = DateSpan.month(of: today),
      let limit = home.limitMinor(for: BudgetPeriod(span: month))
    else { return .noLimit }
    let rate = home.currency == converter.home ? nil : converter.latestRate(of: home.currency, onOrBefore: today)?.rate
    switch HomeConverter.convert(MoneyAmount(amountMinor: limit, currency: home.currency), home: converter.home, rate: rate) {
    case .converted(let minor): return .limit(minor)
    case .awaitingRate: return .awaitingRate
    case .unconvertible: return .noLimit
    }
  }
}

/// The deposits of the closes of periods starting in one calendar month, in the home currency.
public struct SavingsMonth: Sendable, Hashable {
  /// The month's first day.
  public let month: LocalDate
  public let depositedMinor: Int64
  /// The closes recorded for the month, those that put nothing in included.
  public let closes: Int

  static func history(_ book: SavingsBook, home: CurrencyCode) -> [SavingsMonth] {
    var totals = [LocalDate: (deposited: Int128, closes: Int)]()
    for (key, deposit) in book.budgets.deposits {
      guard let month = LocalDate(year: key.periodStart.year, month: key.periodStart.month, day: 1) else { continue }
      var entry = totals[month] ?? (0, 0)
      entry.closes += 1
      if deposit.currency == home { entry.deposited += Int128(max(0, deposit.amountMinor)) }
      totals[month] = entry
    }
    return totals.sorted { $0.key < $1.key }.map { SavingsMonth(month: $0.key, depositedMinor: Int64(clamping: $0.value.deposited), closes: $0.value.closes) }
  }
}
