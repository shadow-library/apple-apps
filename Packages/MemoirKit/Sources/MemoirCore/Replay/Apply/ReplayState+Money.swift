import Foundation
import ShadowCore

/// Money in the game (ruleset v2). Logging covers a day once and earns the daily log XP; a close, a goal milestone and a goal bought each count once per
/// key, the earliest in replay order, and later ones are superseded. Only commands stamped with money rules move any of it.
extension ReplayState {
  mutating func logNoSpend(_ day: NoSpendDay, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    _ = try moneyRules(in: context)
    guard isInLoggingWindow(day.date, in: context) else { throw .outsideLoggingWindow(day.date) }
    guard money.coveredDays[day.date] == nil else { return .superseded }
    noteMoneyActivity(in: context)
    cover(day.date, by: .noSpend, in: context)
    return .applied
  }

  /// A reward is credited; a penalty fines at most the balance, starts its debuff on the account's day and resets the money and saving streaks. A
  /// deposit extends the saving streak, and a close within the limit without one (a trip, a calibration month) leaves it as it was.
  mutating func closePeriod(_ close: BudgetPeriodClose, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    let rules = try moneyRules(in: context)
    let key = MoneyCloseKey(budget: close.budgetId, periodStart: close.periodStart)
    guard money.closes[key] == nil else { return .superseded }
    let date = context.accountDay
    let ruleset = context.ruleset
    let grantKey = "\(close.budgetId.lowercasedString)_\(close.periodStart)"
    let result: MoneyCloseResult
    switch rules.close[intensityMode(for: date, accountDay: date)][close.outcome] {
    case .reward(let amount):
      _ = hero.credit([GrantIntent(key: "moneyclose_\(grantKey)", type: .moneyReward, date: date, xpDelta: amount.xp, coinsDelta: amount.coins)], ruleset: ruleset)
      if amount.xp > 0 { evaluateProgress(on: date, ruleset: ruleset) }
      result = .rewarded(amount)
    case .penalty(let fine, let debuff):
      let applied = hero.fine(GrantIntent(key: "moneyfine_\(grantKey)", type: .moneyFine, date: date), coins: fine, ruleset: ruleset)
      let span = MoneyDebuffSpan(from: date, through: date.adding(days: debuff.days - 1) ?? date, multiplier: debuff.multiplier, command: context.id)
      money.debuffs.append(span)
      money.weekStreak = 0
      money.savingStreak = 0
      result = .fined(intended: fine, applied: applied, debuff: span)
    }
    if close.deposited { money.savingStreak = Exact.adding(money.savingStreak, 1) }
    money.closes[key] = MoneyClose(command: context.id, outcome: close.outcome, deposited: close.deposited, closedOn: date, result: result)
    noteMoneyActivity(in: context)
    return .applied
  }

  mutating func reachMilestone(_ reached: GoalMilestoneReached, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    let rules = try moneyRules(in: context)
    guard money.milestones.insert(GoalMilestoneKey(goal: reached.goalId, milestone: reached.milestone)).inserted else { return .superseded }
    let date = context.accountDay
    let amount = rules.milestones[intensityMode(for: date, accountDay: date)][reached.milestone]
    creditGoalReward(amount, key: "goalmilestone_\(reached.goalId.lowercasedString)_\(reached.milestone.rawValue)", type: .goalMilestone, in: context)
    return .applied
  }

  mutating func buyGoal(_ purchase: GoalPurchase, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    let rules = try moneyRules(in: context)
    guard money.goalsBought.insert(purchase.goalId).inserted else { return .superseded }
    let date = context.accountDay
    let amount = rules.goalPurchase[intensityMode(for: date, accountDay: date)][purchase.outcome]
    creditGoalReward(amount, key: "goalbought_\(purchase.goalId.lowercasedString)", type: .goalBought, in: context)
    return .applied
  }

  /// A day is covered only by logging done on it or within the late window after it, never ahead of the account's day.
  func isInLoggingWindow(_ date: LocalDate, in context: ApplyContext) -> Bool {
    guard let rules = context.ruleset.money else { return false }
    let day = context.accountDay
    return date <= day && day.days(since: date) <= rules.lateDays
  }

  /// The first command to cover a day earns its daily log XP, keyed `moneylog_<date>` and dated that day, under the debuff in force on it.
  mutating func cover(_ date: LocalDate, by source: MoneyLogSource, in context: ApplyContext) {
    guard let rules = context.ruleset.money, money.coveredDays[date] == nil else { return }
    money.coveredDays[date] = MoneyCoverage(source: source, command: context.id)
    let ruleset = context.ruleset
    let reward = debuffed(rules.dailyLog[intensityMode(for: date, accountDay: context.accountDay)], on: date, ruleset: ruleset)
    _ = hero.credit([GrantIntent(key: "moneylog_\(date)", type: .moneyLog, date: date, xpDelta: reward.xp, coinsDelta: reward.coins)], ruleset: ruleset)
    if reward.xp > 0 { evaluateProgress(on: date, ruleset: ruleset) }
  }

  mutating func noteMoneyActivity(in context: ApplyContext) {
    guard context.ruleset.money != nil else { return }
    money.lastActivityDay = max(context.accountDay, money.lastActivityDay ?? context.accountDay)
  }

  /// An XP grant dated under a debuff, from a command stamped with money rules, keeps the debuffed share of its XP after the ceiling; coins are untouched.
  func debuffed(_ amount: RewardAmount, on date: LocalDate, ruleset: Ruleset) -> RewardAmount {
    guard ruleset.money != nil, let multiplier = money.debuffMultiplier(on: date) else { return amount }
    return RewardAmount(xp: Ruleset.debuffed(xp: amount.xp, multiplier: multiplier), coins: amount.coins)
  }

  func debuffed(_ outcome: RewardOutcome, on date: LocalDate, ruleset: Ruleset) -> RewardOutcome {
    let amount = debuffed(RewardAmount(xp: outcome.xp, coins: outcome.coins), on: date, ruleset: ruleset)
    return RewardOutcome(
      xp: amount.xp, coins: outcome.coins, statTick: outcome.statTick, baseXP: outcome.baseXP, modifier: outcome.modifier, streakTier: outcome.streakTier,
      oneShotConsumed: outcome.oneShotConsumed)
  }

  /// A day closing under money rules drops the debuffs that ended more than the late window before it and, once the account has any money activity,
  /// settles the week that ended the late window before it: enough covered days extend the money streak, fewer reset it, and a week the walk never
  /// settled breaks the run.
  mutating func settleMoney(closing date: LocalDate, ruleset: Ruleset) {
    guard let rules = ruleset.money, let weekEnd = date.adding(days: -rules.lateDays) else { return }
    money.debuffs.removeAll { $0.through < weekEnd }
    guard money.lastActivityDay != nil, let weekStart = weekEnd.adding(days: -(LocalDate.daysPerWeek - 1)), weekStart.weekday == rules.weekAnchorWeekday else { return }
    let covered = (0..<LocalDate.daysPerWeek).compactMap { weekStart.adding(days: $0) }.count { money.coveredDays[$0] != nil }
    let continues = money.lastSettledWeekStart.map { $0.adding(days: LocalDate.daysPerWeek) == weekStart } ?? true
    money.weekStreak = covered >= rules.weekMinCovered ? (continues ? Exact.adding(money.weekStreak, 1) : 1) : 0
    money.lastSettledWeekStart = weekStart
  }

  private func moneyRules(in context: ApplyContext) throws(ReplayRefusal) -> MoneyRules {
    guard let rules = context.ruleset.money else { throw .needsNewerRuleset(minimum: Ruleset.v2.version) }
    return rules
  }

  private mutating func creditGoalReward(_ amount: RewardAmount, key: String, type: HeroEventType, in context: ApplyContext) {
    let date = context.accountDay
    _ = hero.credit([GrantIntent(key: key, type: type, date: date, xpDelta: amount.xp, coinsDelta: amount.coins)], ruleset: context.ruleset)
    if amount.xp > 0 { evaluateProgress(on: date, ruleset: context.ruleset) }
    noteMoneyActivity(in: context)
  }
}
