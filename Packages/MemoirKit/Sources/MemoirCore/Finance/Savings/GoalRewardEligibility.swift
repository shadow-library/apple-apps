import Foundation

/// Whether a goal's milestones and purchase earn rewards (D35): only a goal whose target is at least `SavingsRules.rewardTargetThousandths` of Home's
/// monthly limit in force on the day the goal was created, rounded up, so a tiny goal cannot be made and bought again and again for its rewards. Home
/// keeps only its limit in force and one staged change, so for a goal created months ago this reads the limit as Home holds it now for that day.
public enum GoalRewardEligibility: Sendable, Hashable {
  case eligible
  case targetBelowMinimum(minimumMinor: Int64)
  /// Home had no limit, or a zero one, on the goal's first day.
  case homeWithoutLimit
  /// Home is in another currency and has no recorded rate on or before the goal's first day.
  case limitAwaitingRate
  /// The goal is in a currency other than the home one.
  case otherCurrency

  public var isEligible: Bool { self == .eligible }

  static func of(_ goal: SavingsGoalRecord, home: LiveBudget?, converter: BudgetConverter) -> GoalRewardEligibility {
    guard goal.currency == converter.home else { return .otherCurrency }
    guard let home, let limit = home.limitMinor(on: goal.createdOn), limit > 0 else { return .homeWithoutLimit }
    let rate = home.currency == converter.home ? nil : converter.latestRate(of: home.currency, onOrBefore: goal.createdOn)?.rate
    let inHome: Int64
    switch HomeConverter.convert(MoneyAmount(amountMinor: limit, currency: home.currency), home: converter.home, rate: rate) {
    case .converted(let minor): inHome = minor
    case .awaitingRate: return .limitAwaitingRate
    case .unconvertible: return .homeWithoutLimit
    }
    let minimum = Int64(clamping: GoalForecast.ceilDivide(Int128(inHome) * Int128(SavingsRules.rewardTargetThousandths), 1000))
    return goal.targetMinor >= minimum ? .eligible : .targetBelowMinimum(minimumMinor: minimum)
  }
}
