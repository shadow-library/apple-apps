import Foundation
import MemoirCore
import ShadowAppShell

/// Money in the game's words on the Money screen and in the money cards Today shows, localized in `Money.xcstrings`.
enum MoneyGameCopy {
  static func streak(_ weeks: Int) -> String {
    String(localized: "Money streak: \(weeks) weeks", table: "Money")
  }

  static var notStarted: String {
    String(localized: "Log a day’s spending, or say you spent nothing, to start a money streak.", table: "Money")
  }

  static func week(_ week: MoneyWeekProgress) -> String {
    String(localized: "This week: \(week.covered.count) of \(week.required) days logged", table: "Money")
  }

  /// The week before, while its last days can still be logged.
  static func settling(_ week: MoneyWeekProgress) -> String {
    guard !week.isAccounted else { return String(localized: "Last week counts: \(week.covered.count) of \(week.required) days logged", table: "Money") }
    return String(localized: "Last week: \(week.covered.count) of \(week.required) days logged, still open", table: "Money")
  }

  static func savingStreak(_ closes: Int) -> String {
    String(localized: "Saving streak: \(closes) closes", table: "Money")
  }

  static func debuff(_ debuff: MoneyRow.Debuff, locale: Locale) -> String {
    self.debuff(debuff.multiplier, through: debuff.through, locale: locale)
  }

  static func debuff(_ multiplier: Thousandths, through: LocalDate, locale: Locale) -> String {
    let penalty = percent(1000 - multiplier.thousandths, locale: locale)
    return String(localized: "XP −\(penalty) until \(MoneyDates.text(through, locale: locale, showsYear: false))", table: "Money")
  }

  /// Thousandths as a percentage in the owner's locale.
  static func percent(_ thousandths: Int, locale: Locale) -> String {
    (Double(thousandths) / 1000).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
  }

  static func home(_ standing: BudgetPeriodStanding, locale: Locale) -> String {
    String(localized: "Home: \(BudgetRowContent(standing, locale: locale).status)", table: "Money")
  }

  static func outcome(_ outcome: BudgetCloseOutcome, locale: Locale) -> String {
    switch outcome {
    case .withinTypical: String(localized: "Within its limit and under a typical month", table: "Money")
    case .within: String(localized: "Within its limit", table: "Money")
    case .over10: String(localized: "Over its limit by up to \(percent(100, locale: locale))", table: "Money")
    case .over25: String(localized: "Over its limit by up to \(percent(250, locale: locale))", table: "Money")
    case .overMore: String(localized: "Over its limit by more than \(percent(250, locale: locale))", table: "Money")
    case .unscored: String(localized: "Too few days logged to judge", table: "Money")
    }
  }

  static func isGood(_ outcome: BudgetCloseOutcome) -> Bool {
    switch outcome {
    case .withinTypical, .within: true
    case .over10, .over25, .overMore, .unscored: false
    }
  }

  /// What the close did to the hero: the reward, or the fine as far as there were coins to take, then the debuff.
  static func result(_ result: MoneyCloseResult, locale: Locale) -> [String] {
    switch result {
    case .rewarded(let amount):
      var parts = [String]()
      if amount.xp > 0 { parts.append(String(localized: "+\(amount.xp) XP", table: "Money")) }
      if amount.coins > 0 { parts.append(String(localized: "+\(amount.coins) coins", table: "Money")) }
      return parts
    case .fined(_, let applied, let debuff):
      let fine = applied > 0 ? String(localized: "−\(applied) coins", table: "Money") : String(localized: "No coins left to fine", table: "Money")
      return [fine, self.debuff(debuff.multiplier, through: debuff.through, locale: locale)]
    }
  }

  /// The deposit the close's record holds, never a balance of real money; nil when it put nothing in.
  static func deposit(_ deposit: SavingsDeposit?, locale: Locale) -> String? {
    guard let deposit, deposit.amountMinor > 0 else { return nil }
    return String(localized: "\(MoneyText.formatted(deposit.amountMinor, deposit.currency, locale: locale)) saved under budget", table: "Money")
  }

  static func closeName(_ close: MoneyCloseSummary) -> String {
    BudgetCopy.name(id: close.key.budget, stored: close.budgetName)
  }

  static func closePeriod(_ close: MoneyCloseSummary, locale: Locale) -> String {
    String(
      localized: "From \(MoneyDates.text(close.key.periodStart, locale: locale)) · closed \(MoneyDates.text(close.closedOn, locale: locale, showsYear: false))",
      table: "Money")
  }

  static var noSpendToday: String { String(localized: "No spend today", table: "Money") }

  /// A day of the window before today, named from the account's day.
  static func noSpend(on day: LocalDate, today: LocalDate, locale: Locale) -> String {
    if day == today { return noSpendToday }
    if today.days(since: day) == 1 { return String(localized: "Log yesterday as no spend", table: "Money") }
    return String(localized: "Log \(MoneyDates.text(day, locale: locale, showsYear: false)) as no spend", table: "Money")
  }

  /// What covers the account's open day already; nil while nothing does.
  static func covered(_ source: MoneyLogSource?) -> String? {
    switch source {
    case .expense?: String(localized: "Today’s spending is logged.", table: "Money")
    case .noSpend?: String(localized: "Today is logged as a day without spending.", table: "Money")
    case nil: nil
    }
  }

  static func refusal(_ block: ActionBlock) -> String {
    switch block {
    case .alreadyCovered(.expense): String(localized: "That day already has an expense logged.", table: "Money")
    case .alreadyCovered(.noSpend): String(localized: "That day is already logged as no spend.", table: "Money")
    case .loggingWindowClosed: String(localized: "That day is too long ago to log.", table: "Money")
    case .notYetBegun: String(localized: "That day hasn’t started yet.", table: "Money")
    case .questInactive, .notScheduled, .dayPassed, .notAccountDay, .alreadyRecorded, .alreadyRescheduled, .notAllowedFor, .rescheduleCapReached,
      .nothingRecorded, .nothingToLock, .notLocked, .recoveryClosed, .lockedInTodaysPlan:
      String(localized: "That day can’t be logged now.", table: "Money")
    }
  }

  static func problem(_ outcome: NoSpendOutcome) -> String? {
    switch outcome {
    case .logged, .cancelled: nil
    case .unavailable(let block): refusal(block)
    case .failed(let error): String(localized: "Couldn’t log the day: \(error.headline)", table: "Money")
    }
  }
}
