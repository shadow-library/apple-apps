import Foundation
import ShadowCore
import ShadowStore

/// A savings goal as the owner edits it; the target is in the home currency.
public struct GoalDraft: Hashable, Sendable {
  public var name: String
  public var symbol: String
  public var targetMinor: Int64
  public var targetDate: LocalDate?

  public init(name: String, symbol: String, targetMinor: Int64, targetDate: LocalDate? = nil) {
    self.name = name
    self.symbol = symbol
    self.targetMinor = targetMinor
    self.targetDate = targetDate
  }

  public init(_ goal: SavingsGoalRecord) {
    self.init(name: goal.name, symbol: goal.symbol, targetMinor: goal.targetMinor, targetDate: goal.targetDate)
  }
}

/// The only writer of savings goals, in the caller's main-store write. Goals are settings, except buying one that earns rewards, which issues `goal.bought`
/// with the record.
/// `today` is the account's day.
public enum GoalEdits {
  /// A new goal joins after the last active one, the goals already active keeping their ranks.
  @discardableResult
  public static func create(_ draft: GoalDraft, id: UUID, today: LocalDate, in transaction: inout WriteTransaction) throws(FinanceError) -> SavingsGoalRecord {
    guard let settings = try FinanceLedger.settings(in: transaction) else { throw .settingsAbsent }
    let name = try required(draft.name, else: .goalNameRequired)
    let symbol = try required(draft.symbol, else: .goalSymbolRequired)
    try checkTarget(draft.targetMinor)
    if let date = draft.targetDate { try checkTargetDate(date, today: today) }
    guard case .absent = try reading(id, in: transaction) else { throw .goalExists(id) }
    let active = try activeGoals(in: transaction)
    guard active.count < SavingsRules.maximumActiveGoals else { throw .goalLimitReached(maximum: SavingsRules.maximumActiveGoals) }
    var rank = SavingsGoalRank.between(active.last?.rank, nil)
    if rank == nil { rank = try respread(active, in: &transaction, count: active.count + 1).last }
    guard let rank else { preconditionFailure("spreading ranks for one goal or more gives one for the last") }
    let goal = SavingsGoalRecord(
      id: id, name: name, symbol: symbol, targetMinor: draft.targetMinor, currency: settings.defaultCurrency, targetDate: draft.targetDate, rank: rank, createdOn: today)
    try written { () throws(MemoirRecordError) in try goal.create(in: &transaction) }
    return goal
  }

  /// `nil`, writing nothing, when the change moves nothing. A bought or abandoned goal keeps its target and date; its name and symbol can still change.
  /// The target date is checked only when it moves, so a goal whose date has passed can still be renamed.
  @discardableResult
  public static func update(_ id: UUID, today: LocalDate, in transaction: inout WriteTransaction, _ change: (inout GoalDraft) -> Void) throws(FinanceError)
    -> SavingsGoalRecord?
  {
    let current = try present(id, in: transaction)
    let opening = GoalDraft(current)
    var draft = opening
    change(&draft)
    guard draft != opening else { return nil }
    var updated = current
    updated.name = try required(draft.name, else: .goalNameRequired)
    updated.symbol = try required(draft.symbol, else: .goalSymbolRequired)
    if draft.targetMinor != opening.targetMinor || draft.targetDate != opening.targetDate {
      guard current.state == .known(.active) else { throw .goalNotActive(id) }
      try checkTarget(draft.targetMinor)
      if let date = draft.targetDate, date != opening.targetDate { try checkTargetDate(date, today: today) }
      updated.targetMinor = draft.targetMinor
      updated.targetDate = draft.targetDate
    }
    guard updated != current else { return nil }
    let edited = updated
    try written { () throws(MemoirRecordError) in try SavingsGoalRecord.edit(id: id, in: &transaction) { $0 = edited } }
    return edited
  }

  /// Moves an active goal to `index` in the fill order of the active goals, clamped to it, rewriting only that goal's rank. Only when no rank fits between
  /// its new neighbours (two devices gave them the same rank, or ranks grew to their longest) are every active goal's ranks spread out again. `nil` when
  /// the goal is already there.
  @discardableResult
  public static func reorder(_ id: UUID, toIndex index: Int, in transaction: inout WriteTransaction) throws(FinanceError) -> SavingsGoalRecord? {
    let goal = try present(id, in: transaction)
    guard goal.state == .known(.active) else { throw .goalNotActive(id) }
    let active = try activeGoals(in: transaction)
    guard let from = active.firstIndex(where: { $0.id == id }) else { throw .goalNotActive(id) }
    var others = active
    others.remove(at: from)
    let to = min(max(index, 0), others.count)
    guard to != from else { return nil }
    let lower = to > 0 ? others[to - 1].rank : nil
    let upper = to < others.count ? others[to].rank : nil
    if let rank = SavingsGoalRank.between(lower, upper) {
      try written { () throws(MemoirRecordError) in try SavingsGoalRecord.edit(id: id, in: &transaction) { $0.rank = rank } }
      return try present(id, in: transaction)
    }
    others.insert(goal, at: to)
    _ = try respread(others, in: &transaction, count: others.count)
    return try present(id, in: transaction)
  }

  /// Marks an active goal bought and, when the goal earns rewards (`GoalRewardEligibility`), issues `goal.bought` in the same write; a goal too small for
  /// rewards is only marked, and nil is returned. Its purchase is every live expense naming it: `within` when their whole amounts add up, in home, to at
  /// most the target. Refused while no expense names the goal (`goalNotPurchased`), so a goal is bought by recording what bought it, and, for a goal that
  /// earns rewards, while one of them waits for a rate (`savingsAwaitingRate`). Whatever the goal's share held beyond its draws returns to savings.
  @discardableResult
  public static func markBought(_ id: UUID, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws(CommandIssueError) -> MemoirCommand? {
    let outcome: GoalPurchaseOutcome?
    do throws(FinanceError) {
      let goal = try present(id, in: transaction)
      guard goal.state == .known(.active) else { throw .goalNotActive(id) }
      let ledger = try FinanceLedger.load(from: transaction)
      guard let settings = ledger.settings, let converter = ledger.converter else { throw .settingsAbsent }
      let purchase = ledger.expenses.filter { $0.goal == goal.id }
      guard !purchase.isEmpty else { throw .goalNotPurchased(goal.id) }
      let home =
        try Budgets.live(in: transaction).home
        ?? LiveBudget(
          record: BudgetRecord(id: HomeBudget.id, currency: settings.defaultCurrency, period: .monthly, createdOn: goal.createdOn), settings: settings)
      let eligibility = GoalRewardEligibility.of(goal, home: home, converter: BudgetConverter(home: settings.defaultCurrency, rates: ledger.rates))
      outcome = eligibility.isEligible ? try purchaseOutcome(of: goal, purchase: purchase, converter: converter) : nil
      try written { () throws(MemoirRecordError) in try SavingsGoalRecord.edit(id: id, in: &transaction) { $0.state = .known(.bought) } }
    } catch {
      throw .refused(.finance(error))
    }
    guard let outcome else { return nil }
    return try issuer.issue(.goalBought(GoalPurchase(goalId: id, outcome: outcome)), in: &transaction)
  }

  /// Its share returns to savings for the goals after it.
  @discardableResult
  public static func abandon(_ id: UUID, in transaction: inout WriteTransaction) throws(FinanceError) -> SavingsGoalRecord {
    let goal = try present(id, in: transaction)
    guard goal.state == .known(.active) else { throw .goalNotActive(id) }
    try written { () throws(MemoirRecordError) in try SavingsGoalRecord.edit(id: id, in: &transaction) { $0.state = .known(.abandoned) } }
    return try present(id, in: transaction)
  }

  /// A goal in any state; expenses naming it keep the name, and what they drew counts as any other withdrawal. Rewards it was given stay.
  public static func delete(_ id: UUID, in transaction: inout WriteTransaction) throws(FinanceError) {
    _ = try present(id, in: transaction)
    try written { () throws(MemoirRecordError) in _ = try SavingsGoalRecord.remove(SavingsGoalRecord.ref(id), in: &transaction) }
  }

  private static func purchaseOutcome(of goal: SavingsGoalRecord, purchase: [ExpenseRecord], converter: HomeConverter) throws(FinanceError) -> GoalPurchaseOutcome {
    var total = Int128(0)
    for expense in purchase {
      switch converter.homeAmount(of: expense) {
      case .converted(let minor): total += Int128(minor)
      case .awaitingRate: throw .savingsAwaitingRate
      case .unconvertible(let error): throw error
      }
    }
    return total <= Int128(goal.targetMinor) ? .within : .over
  }

  /// Gives `goals`, in order, ranks spread over single digits, and returns the ranks for `count` goals, the extra ones after them.
  private static func respread(_ goals: [SavingsGoalRecord], in transaction: inout WriteTransaction, count: Int) throws(FinanceError) -> [SavingsGoalRank] {
    guard let ranks = SavingsGoalRank.spread(count) else { throw .goalLimitReached(maximum: SavingsRules.maximumActiveGoals) }
    for (goal, rank) in zip(goals, ranks) where goal.rank != rank {
      try written { () throws(MemoirRecordError) in try SavingsGoalRecord.edit(id: goal.id, in: &transaction) { $0.rank = rank } }
    }
    return ranks
  }

  private static func activeGoals(in transaction: borrowing WriteTransaction) throws(FinanceError) -> [SavingsGoalRecord] {
    let listing: MemoirListing<MemoirEntry<SavingsGoalRecord>>
    do throws(StoreError) {
      listing = try SavingsGoalRecord.listing(in: transaction)
    } catch {
      throw FinanceError(error)
    }
    return listing.entries.filter { !$0.isRemoved && $0.record.state == .known(.active) }.map(\.record).sorted(by: SavingsGoalRecord.precedes)
  }

  private static func required(_ text: String, else error: FinanceError) throws(FinanceError) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw error }
    return trimmed
  }

  private static func checkTarget(_ target: Int64) throws(FinanceError) {
    guard target > 0 else { throw .goalTargetNotPositive(target) }
  }

  private static func checkTargetDate(_ date: LocalDate, today: LocalDate) throws(FinanceError) {
    guard date >= today else { throw .goalTargetDatePassed(earliest: today) }
  }

  private static func present(_ id: UUID, in transaction: borrowing WriteTransaction) throws(FinanceError) -> SavingsGoalRecord {
    switch try reading(id, in: transaction) {
    case .readable(let entry) where !entry.isRemoved: return entry.record
    case .readable, .absent: throw .goalAbsent(id)
    case .unreadable: throw .unreadable(SavingsGoalRecord.ref(id))
    }
  }

  private static func reading(_ id: UUID, in transaction: borrowing WriteTransaction) throws(FinanceError) -> MemoirReading<MemoirEntry<SavingsGoalRecord>> {
    do throws(StoreError) {
      return try SavingsGoalRecord.read(id: id, in: transaction)
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
