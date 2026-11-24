import Foundation
import ShadowStore

/// A budget as the owner edits it: the limit and the one-off threshold are the latest values, those a staged change will bring, so setting the value in
/// force again withdraws a pending change.
public struct BudgetDraft: Hashable, Sendable {
  public var name: String?
  public var currency: CurrencyCode
  public var limitMinor: Int64?
  public var period: BudgetPeriodKind
  public var oneOffFromMinor: Int64?

  public init(name: String? = nil, currency: CurrencyCode, limitMinor: Int64? = nil, period: BudgetPeriodKind, oneOffFromMinor: Int64? = nil) {
    self.name = name
    self.currency = currency
    self.limitMinor = limitMinor
    self.period = period
    self.oneOffFromMinor = oneOffFromMinor
  }

  public init(_ budget: LiveBudget, on today: LocalDate) {
    self.init(
      name: budget.record.name, currency: budget.currency, limitMinor: budget.limitStaging.latest(on: today), period: budget.record.period,
      oneOffFromMinor: budget.oneOffStaging.latest(on: today))
  }
}

/// The only writer of budgets, in the caller's main-store write. Budgets are settings: no command is issued. `today` is the account's day.
public enum BudgetEdits {
  /// How many days before today a trip may start, so a trip made afterwards cannot take days already spent out of a month about to close.
  public static let tripBackdatingDays = 3

  @discardableResult
  public static func create(_ draft: BudgetDraft, id: UUID, today: LocalDate, in transaction: inout WriteTransaction) throws(FinanceError) -> BudgetRecord {
    guard id != HomeBudget.id else { throw .homeBudgetFixed }
    _ = try ISO4217.exponent(of: draft.currency)
    let name = try requiredName(draft.name)
    guard let limit = draft.limitMinor else { throw .budgetLimitRequired }
    try checkAmount(limit)
    if let threshold = draft.oneOffFromMinor { try checkAmount(threshold) }
    try checkDates(draft.period)
    try checkStart(draft.period, today: today)
    guard case .absent = try reading(id, in: transaction) else { throw .budgetExists(id) }
    try HomeBudget.ensure(on: today, in: &transaction)
    try checkConflicts(of: id, currency: draft.currency, period: draft.period, in: transaction)
    let record = BudgetRecord(
      id: id, name: name, currency: draft.currency, limitMinor: limit, period: draft.period, oneOffFromMinor: draft.oneOffFromMinor, createdOn: today)
    try written { () throws(MemoirRecordError) in try record.create(in: &transaction) }
    return record
  }

  /// `nil`, writing nothing, when the change moves nothing. Home keeps its name, currency and period; another budget keeps its currency and kind.
  @discardableResult
  public static func update(_ id: UUID, today: LocalDate, in transaction: inout WriteTransaction, _ change: (inout BudgetDraft) -> Void) throws(FinanceError)
    -> BudgetRecord?
  {
    if id == HomeBudget.id { try HomeBudget.ensure(on: today, in: &transaction) }
    let current = try present(id, in: transaction)
    let budget = LiveBudget(record: current, settings: current.isHome ? try FinanceLedger.settings(in: transaction) : nil)
    let opening = BudgetDraft(budget, on: today)
    var draft = opening
    change(&draft)
    guard draft != opening else { return nil }
    if current.isHome, draft.name != opening.name || draft.currency != opening.currency || draft.period != opening.period { throw .homeBudgetFixed }
    guard draft.currency == opening.currency else { throw .budgetFieldFixed(BudgetField.currency.rawValue) }
    var updated = current
    if !current.isHome { updated.name = try requiredName(draft.name) }
    if draft.period != opening.period {
      try checkPeriodMove(from: opening.period, to: draft.period, today: today)
      try checkConflicts(of: id, currency: current.currency, period: draft.period, in: transaction)
      updated.period = draft.period
    }
    if draft.limitMinor != opening.limitMinor {
      guard let limit = draft.limitMinor else { throw .budgetLimitRequired }
      try checkAmount(limit)
      let staging: BudgetStaging
      switch updated.period {
      case .monthly: staging = try budget.limitStaging.monthlyLimit(to: limit, today: today)
      case .trip(let from, _): staging = try budget.limitStaging.tripLimit(to: limit, startingOn: from, today: today)
      }
      updated.limitMinor = staging.base
      updated.stagedLimit = staging.staged
    }
    if draft.oneOffFromMinor != opening.oneOffFromMinor {
      if let threshold = draft.oneOffFromMinor { try checkAmount(threshold) }
      let staging = try budget.oneOffStaging.oneOff(to: draft.oneOffFromMinor, today: today)
      updated.oneOffFromMinor = staging.base
      updated.stagedOneOff = staging.staged
    }
    guard updated != current else { return nil }
    let edited = updated
    try written { () throws(MemoirRecordError) in try BudgetRecord.edit(id: id, in: &transaction) { $0 = edited } }
    return edited
  }

  /// Expenses and subscriptions that named the budget count by the assignment rule again; nothing else is written.
  public static func delete(_ id: UUID, in transaction: inout WriteTransaction) throws(FinanceError) {
    guard id != HomeBudget.id else { throw .homeBudgetFixed }
    _ = try present(id, in: transaction)
    try written { () throws(MemoirRecordError) in _ = try BudgetRecord.remove(BudgetRecord.ref(id), in: &transaction) }
  }

  private static func requiredName(_ name: String?) throws(FinanceError) -> String {
    guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { throw .budgetNameRequired }
    return trimmed
  }

  private static func checkAmount(_ amount: Int64) throws(FinanceError) {
    guard amount >= 0 else { throw .negativeLimit(amount) }
  }

  private static func checkDates(_ period: BudgetPeriodKind) throws(FinanceError) {
    guard case .trip(let from, let through) = period else { return }
    guard from <= through else { throw .invalidTripDates }
  }

  private static func checkPeriodMove(from opening: BudgetPeriodKind, to period: BudgetPeriodKind, today: LocalDate) throws(FinanceError) {
    guard case .trip(let start, _) = opening, case .trip(let from, _) = period else { throw .budgetFieldFixed(BudgetField.period.rawValue) }
    try checkDates(period)
    if today >= start, from != start { throw .tripStartFixed }
    if from != start { try checkStart(period, today: today) }
  }

  private static func checkStart(_ period: BudgetPeriodKind, today: LocalDate) throws(FinanceError) {
    guard case .trip(let from, _) = period else { return }
    guard let earliest = today.adding(days: -tripBackdatingDays) else { throw .dateOutOfRange }
    guard from >= earliest else { throw .tripStartTooEarly(earliest: earliest) }
  }

  private static func checkConflicts(of id: UUID, currency: CurrencyCode, period: BudgetPeriodKind, in transaction: borrowing WriteTransaction) throws(FinanceError) {
    for other in try Budgets.live(in: transaction).live where other.id != id {
      switch (period, other.record.period) {
      case (.monthly, .monthly) where other.currency == currency:
        throw .currencyTaken(currency)
      case (.trip(let from, let through), .trip(let otherFrom, let otherThrough)) where from <= otherThrough && otherFrom <= through:
        throw .tripsOverlap(other.id)
      default:
        continue
      }
    }
  }

  private static func present(_ id: UUID, in transaction: borrowing WriteTransaction) throws(FinanceError) -> BudgetRecord {
    switch try reading(id, in: transaction) {
    case .readable(let entry) where !entry.isRemoved || entry.record.isHome: return entry.record
    case .readable, .absent: throw .budgetAbsent(id)
    case .unreadable: throw .unreadable(BudgetRecord.ref(id))
    }
  }

  private static func reading(_ id: UUID, in transaction: borrowing WriteTransaction) throws(FinanceError) -> MemoirReading<MemoirEntry<BudgetRecord>> {
    do throws(StoreError) {
      return try BudgetRecord.read(id: id, in: transaction)
    } catch {
      throw FinanceError(error)
    }
  }

  private static func written(_ body: () throws(MemoirRecordError) -> Void) throws(FinanceError) {
    do throws(MemoirRecordError) {
      try body()
    } catch {
      throw FinanceError(error)
    }
  }
}
