import Foundation
import ShadowCore

public enum SavingsPaceState: Sendable, Hashable {
  /// Fewer than `SavingsRules.paceCalibrationMonths` months have closed since the vault's first deposit-capable close; `monthsLeft` counts the closes
  /// still to come, those of months a monthly budget is still calibrating in included.
  case calibrating(monthsLeft: Int)
  /// The mean of the counted months' deposits, halves up; zero when none put anything in.
  case known(perMonthMinor: Int64)
}

/// What savings gain in a month, from the last `SavingsRules.paceMonths` closed months before the current one. A month is closed once any monthly budget's
/// close for it is recorded, and it counts with the deposits of every budget's closes of periods starting in it, zero when they put nothing in. Months count
/// only from the vault's first deposit-capable close: the close of a monthly budget's month past its calibration (the budget had
/// `BudgetThresholds.calibrationMonths` complete months before it), since a calibrating month never deposits and would read as a month that saved nothing.
public struct SavingsPace: Sendable, Hashable {
  public let months: [SavingsMonth]
  public let state: SavingsPaceState

  public var perMonthMinor: Int64? {
    guard case .known(let minor) = state else { return nil }
    return minor
  }

  static func make(_ book: SavingsBook, history: [SavingsMonth], today: LocalDate) -> SavingsPace {
    guard let current = LocalDate(year: today.year, month: today.month, day: 1) else { return SavingsPace(months: [], state: .calibrating(monthsLeft: 0)) }
    let live = book.budgets.liveBudgets(today: today).map(\.record)
    let records = Dictionary((book.budgetRecords + live).map { ($0.id, $0) }) { first, _ in first }
    let monthlyCloses = book.budgets.deposits.keys.filter { records[$0.budget]?.period == .monthly }
    let start = monthlyCloses.filter { key in records[key.budget].flatMap(capableFrom).map { key.periodStart >= $0 } ?? false }.map(\.periodStart).min()
    let calibration = SavingsRules.paceCalibrationMonths
    guard let start else {
      let earliest = live.filter { $0.period == .monthly }.compactMap(capableFrom).min()
      let wait = earliest.map { max(0, $0.monthIndex - current.monthIndex) } ?? 0
      return SavingsPace(months: [], state: .calibrating(monthsLeft: wait + calibration))
    }
    let closed = Set(monthlyCloses.map(\.periodStart).filter { $0 >= start && $0 < current }.compactMap { LocalDate(year: $0.year, month: $0.month, day: 1) })
    let counted = closed.sorted().suffix(SavingsRules.paceMonths)
    let byMonth = Dictionary(history.map { ($0.month, $0) }) { first, _ in first }
    let months = counted.map { byMonth[$0] ?? SavingsMonth(month: $0, depositedMinor: 0, closes: 0) }
    guard months.count >= calibration else { return SavingsPace(months: months, state: .calibrating(monthsLeft: calibration - months.count)) }
    let total = months.reduce(Int128(0)) { $0 + Int128($1.depositedMinor) }
    return SavingsPace(months: months, state: .known(perMonthMinor: Int64(clamping: Exact.roundHalfUp(total, Int128(months.count)))))
  }

  /// The first month of a monthly budget that can deposit: `calibrationMonths` after its first complete month.
  private static func capableFrom(_ budget: BudgetRecord) -> LocalDate? {
    guard budget.period == .monthly, let created = LocalDate(year: budget.createdOn.year, month: budget.createdOn.month, day: 1) else { return nil }
    let firstComplete = budget.createdOn.day == 1 ? created : created.adding(months: 1)
    return firstComplete?.adding(months: BudgetThresholds.calibrationMonths)
  }
}

/// A non-essential category whose spending, `SavingsRules.leverThousandths` lower, would bring a goal at least a month sooner.
public struct GoalLever: Sendable, Hashable {
  public let category: CategoryKey
  /// The saving a month, in the home currency: the share of the category's mean monthly spending over the last `SavingsRules.leverMonths` complete months.
  public let savingPerMonthMinor: Int64
  public let monthsSooner: Int
  public let eta: LocalDate
}

/// How much later a goal arrives because of this month's withdrawals that bought no goal.
public struct GoalDelay: Sendable, Hashable {
  public let byDays: Int
  /// The largest of those withdrawals' expense.
  public let cause: UUID
  public let withdrawnMinor: Int64
}

/// What a goal with a target date needs to arrive on time. `monthsLeft` counts the closes that land by the target date's month: the current month's close
/// lands in the next month, so a target in the current month has none.
public struct GoalTargetNeed: Sendable, Hashable {
  public let target: LocalDate
  public let monthsLeft: Int
  /// Today through the target date.
  public let daysLeft: Int
  public let perMonthMinor: Int64
  public let perDayMinor: Int64
}

/// One state per goal, the first that holds in this order: reached, repaying, calibrating, noPace, behind, pushedBack, lever, aheadOfTarget, onTrack.
public enum GoalForecastState: Sendable, Hashable {
  case onTrack(eta: LocalDate)
  case aheadOfTarget(eta: LocalDate, target: LocalDate)
  /// What the goal needs beyond the pace, a month and a day, rounded up.
  case behind(extraPerMonthMinor: Int64, extraPerDayMinor: Int64)
  case lever(category: CategoryKey, monthsSooner: Int)
  case noPace
  case calibrating(monthsLeft: Int)
  case pushedBack(byDays: Int, cause: UUID)
  case repaying(owedMinor: Int64)
  /// The share has reached the target: the goal can be bought from `buyFrom`, today or the end of its cooling-off.
  case reached(buyFrom: LocalDate)
}

/// Where an active goal stands against the pace. Deposits fill goals in order, so a goal arrives once the deposits have repaid what savings owe and filled
/// it and every goal before it: its `aheadMinor` is that sum, and the estimate counts `ceil(aheadMinor / pace)` closes, the current month's first, landing
/// the month after each closes. `eta` is that month's first day. A target date that has passed reads as none.
public struct GoalForecast: Sendable, Hashable, Identifiable {
  public let goal: UUID
  public let state: GoalForecastState
  public let shareMinor: Int64
  public let remainingMinor: Int64
  /// What deposits must bring before the goal is full: what savings owe and the remaining of this goal and every goal before it.
  public let aheadMinor: Int64
  /// Nil while the pace is unknown or zero, and once the goal is reached.
  public let eta: LocalDate?
  public let need: GoalTargetNeed?
  public let lever: GoalLever?
  public let delay: GoalDelay?

  public var id: UUID { goal }

  struct Inputs {
    let today: LocalDate
    let currentMonth: LocalDate
    let pace: SavingsPace
    let allocation: SavingsAllocation
    /// The allocation with this month's withdrawals that bought no goal back in savings; nil without any.
    let undelayed: (allocation: SavingsAllocation, cause: UUID, withdrawnMinor: Int64)?
    let levers: [(category: CategoryKey, savingMinor: Int64)]
  }

  static func make(_ inputs: Inputs) -> [GoalForecast] {
    var ahead = Int128(inputs.allocation.owedMinor)
    var undelayedAhead = inputs.undelayed.map { Int128($0.allocation.owedMinor) }
    return inputs.allocation.active.map { share in
      ahead += Int128(share.remainingMinor)
      if let undelayed = inputs.undelayed, let other = undelayed.allocation.share(of: share.id) { undelayedAhead? += Int128(other.remainingMinor) }
      return make(share, ahead: ahead, undelayedAhead: undelayedAhead, inputs: inputs)
    }
  }

  private static func make(_ share: GoalShare, ahead: Int128, undelayedAhead: Int128?, inputs: Inputs) -> GoalForecast {
    let pace = inputs.pace.perMonthMinor.flatMap { $0 > 0 ? Int128($0) : nil }
    let closes = pace.map { ceilDivide(ahead, $0) }
    let eta = closes.flatMap { month(after: inputs.currentMonth, closes: $0) }
    let need = targetNeed(share.goal, ahead: ahead, inputs: inputs)
    let lever = pace.flatMap { pace in closes.flatMap { lever(ahead: ahead, pace: pace, closes: $0, inputs: inputs) } }
    var delay: GoalDelay?
    if let pace, let closes, let undelayed = inputs.undelayed, let undelayedAhead, let eta {
      let sooner = ceilDivide(max(0, undelayedAhead), pace)
      if sooner < closes, let earlier = month(after: inputs.currentMonth, closes: sooner) {
        delay = GoalDelay(byDays: eta.days(since: earlier), cause: undelayed.cause, withdrawnMinor: undelayed.withdrawnMinor)
      }
    }
    let state: GoalForecastState
    if share.remainingMinor == 0 {
      let cooled = share.goal.createdOn.adding(days: SavingsRules.coolingOffDays) ?? share.goal.createdOn
      state = .reached(buyFrom: max(inputs.today, cooled))
    } else if inputs.allocation.owedMinor > 0 {
      state = .repaying(owedMinor: inputs.allocation.owedMinor)
    } else if case .calibrating(let monthsLeft) = inputs.pace.state {
      state = .calibrating(monthsLeft: monthsLeft)
    } else if let pace, let closes, let eta {
      state = settledState(eta: eta, closes: closes, pace: pace, ahead: ahead, need: need, delay: delay, lever: lever)
    } else {
      state = .noPace
    }
    let reached = share.remainingMinor == 0
    return GoalForecast(
      goal: share.id, state: state, shareMinor: share.shareMinor, remainingMinor: share.remainingMinor, aheadMinor: Int64(clamping: ahead), eta: reached ? nil : eta,
      need: reached ? nil : need, lever: reached ? nil : lever, delay: reached ? nil : delay)
  }

  private static func settledState(
    eta: LocalDate, closes: Int128, pace: Int128, ahead: Int128, need: GoalTargetNeed?, delay: GoalDelay?, lever: GoalLever?
  ) -> GoalForecastState {
    if let need, closes > Int128(need.monthsLeft) {
      let extra = ahead - pace * Int128(need.monthsLeft)
      return .behind(
        extraPerMonthMinor: Int64(clamping: ceilDivide(extra, Int128(max(1, need.monthsLeft)))),
        extraPerDayMinor: Int64(clamping: ceilDivide(extra, Int128(need.daysLeft))))
    }
    if let delay { return .pushedBack(byDays: delay.byDays, cause: delay.cause) }
    if let lever { return .lever(category: lever.category, monthsSooner: lever.monthsSooner) }
    if let need, eta.monthIndex < need.target.monthIndex { return .aheadOfTarget(eta: eta, target: need.target) }
    return .onTrack(eta: eta)
  }

  private static func targetNeed(_ goal: SavingsGoalRecord, ahead: Int128, inputs: Inputs) -> GoalTargetNeed? {
    guard let target = goal.targetDate, target >= inputs.today else { return nil }
    let monthsLeft = max(0, target.monthIndex - inputs.currentMonth.monthIndex)
    let daysLeft = target.days(since: inputs.today) + 1
    return GoalTargetNeed(
      target: target, monthsLeft: monthsLeft, daysLeft: daysLeft, perMonthMinor: Int64(clamping: ceilDivide(ahead, Int128(max(1, monthsLeft)))),
      perDayMinor: Int64(clamping: ceilDivide(ahead, Int128(daysLeft))))
  }

  private static func lever(ahead: Int128, pace: Int128, closes: Int128, inputs: Inputs) -> GoalLever? {
    var best: (lever: GoalLever, saving: Int64)?
    for candidate in inputs.levers {
      let faster = ceilDivide(ahead, pace + Int128(candidate.savingMinor))
      let sooner = closes - faster
      guard sooner >= 1, let eta = month(after: inputs.currentMonth, closes: faster) else { continue }
      let lever = GoalLever(category: candidate.category, savingPerMonthMinor: candidate.savingMinor, monthsSooner: Int(clamping: sooner), eta: eta)
      if let current = best {
        if lever.monthsSooner < current.lever.monthsSooner { continue }
        if lever.monthsSooner == current.lever.monthsSooner, candidate.savingMinor <= current.saving { continue }
      }
      best = (lever, candidate.savingMinor)
    }
    return best?.lever
  }

  private static func month(after current: LocalDate, closes: Int128) -> LocalDate? {
    guard let months = Int(exactly: closes) else { return nil }
    return current.adding(months: months)
  }

  /// Rounded up, for a positive divisor; zero for anything at or below zero.
  static func ceilDivide(_ numerator: Int128, _ denominator: Int128) -> Int128 {
    guard numerator > 0 else { return 0 }
    return (numerator + denominator - 1) / denominator
  }
}
