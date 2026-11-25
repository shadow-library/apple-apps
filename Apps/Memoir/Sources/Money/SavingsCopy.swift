import Foundation
import MemoirCore

/// Savings in the owner's words, localized in `Money.xcstrings`: what budgets left unspent, never a balance of real money.
nonisolated enum SavingsCopy {
  static var title: String { String(localized: "Saved under budget", table: "Money") }

  static var explanation: String {
    String(localized: "What your monthly budgets left unspent when each month closed. It’s a tally to plan with, not money in an account.", table: "Money")
  }

  static func repaying(_ owedMinor: Int64, home: CurrencyCode, locale: Locale) -> String {
    String(localized: "You’ll pay back \(MoneyText.formatted(owedMinor, home, locale: locale)) first", table: "Money")
  }

  static func available(_ balance: SavingsBalance, locale: Locale) -> String {
    String(localized: "Available to draw: \(MoneyText.formatted(balance.availableMinor, balance.home, locale: locale))", table: "Money")
  }

  static func borrowing(_ balance: SavingsBalance, locale: Locale) -> String {
    switch balance.borrowing {
    case .limit(let minor):
      let limit = MoneyText.formatted(minor, balance.home, locale: locale)
      return String(localized: "Savings can go up to \(limit) below zero, as much as Home’s monthly limit; later months pay it back first.", table: "Money")
    case .noLimit: return String(localized: "Home has no monthly limit, so nothing can be drawn beyond what’s saved.", table: "Money")
    case .awaitingRate: return String(localized: "What can be drawn beyond what’s saved waits for an exchange rate for Home’s limit.", table: "Money")
    }
  }

  /// What the balance leaves out instead of guessing at it.
  static func notes(_ balance: SavingsBalance) -> [String] {
    var notes = [String]()
    let pending = balance.pendingWithdrawals
    if pending.awaitingRate > 0 {
      notes.append(String(localized: "\(pending.awaitingRate) draws wait for an exchange rate and aren’t counted yet.", table: "Money"))
    }
    if pending.unconvertible > 0 {
      notes.append(String(localized: "\(pending.unconvertible) draws can’t be converted and aren’t counted.", table: "Money"))
    }
    if balance.depositsInOtherCurrencies > 0 {
      notes.append(String(localized: "\(balance.depositsInOtherCurrencies) deposits were made in another currency and are set aside.", table: "Money"))
    }
    return notes
  }

  static func pace(_ pace: SavingsPace, home: CurrencyCode, locale: Locale) -> String {
    switch pace.state {
    case .known(let minor):
      let months = String(localized: "the last \(pace.months.count) months", table: "Money")
      return String(localized: "About \(MoneyText.formatted(minor, home, locale: locale)) a month over \(months)", table: "Money")
    case .calibrating(let monthsLeft) where monthsLeft > 0:
      return String(localized: "A monthly pace shows once \(String(localized: "\(monthsLeft) more months", table: "Money")) have closed", table: "Money")
    case .calibrating:
      return String(localized: "A monthly pace shows once a few more months have closed", table: "Money")
    }
  }

  static func liveMonth(_ live: SavingsLiveMonth, home: CurrencyCode, locale: Locale) -> String {
    String(localized: "This month is on pace to add \(MoneyText.formatted(live.projectedMinor, home, locale: locale)).", table: "Money")
  }

  static func liveMonthPending(_ live: SavingsLiveMonth) -> String? {
    guard live.pending.count > 0 else { return nil }
    return String(localized: "\(live.pending.count) budgets wait for an exchange rate and aren’t in it yet.", table: "Money")
  }

  static func month(_ month: SavingsMonth, home: CurrencyCode, locale: Locale) -> (title: String, amount: String) {
    let amount =
      month.depositedMinor > 0 ? MoneyText.formatted(month.depositedMinor, home, locale: locale) : String(localized: "Nothing put aside", table: "Money")
    return (MoneyDates.month(month.month, locale: locale), amount)
  }
}

/// Savings goals in the owner's words, localized in `Money.xcstrings`. A forecast says what would help, never what went wrong.
nonisolated enum GoalCopy {
  /// The symbols a goal can be given; a goal synced from another device keeps one outside them.
  static let symbols = [
    "bicycle", "car.fill", "airplane", "house.fill", "sofa.fill", "laptopcomputer", "iphone", "camera.fill", "headphones", "gamecontroller.fill",
    "guitars.fill", "gift.fill", "graduationcap.fill", "pawprint.fill", "tent.fill", "heart.fill",
  ]

  static func symbolName(_ symbol: String) -> String {
    switch symbol {
    case "bicycle": String(localized: "Bike", table: "Money")
    case "car.fill": String(localized: "Car", table: "Money")
    case "airplane": String(localized: "Travel", table: "Money")
    case "house.fill": String(localized: "Home", table: "Money")
    case "sofa.fill": String(localized: "Furniture", table: "Money")
    case "laptopcomputer": String(localized: "Computer", table: "Money")
    case "iphone": String(localized: "Phone", table: "Money")
    case "camera.fill": String(localized: "Camera", table: "Money")
    case "headphones": String(localized: "Headphones", table: "Money")
    case "gamecontroller.fill": String(localized: "Games", table: "Money")
    case "guitars.fill": String(localized: "Music", table: "Money")
    case "gift.fill": String(localized: "Gift", table: "Money")
    case "graduationcap.fill": String(localized: "Learning", table: "Money")
    case "pawprint.fill": String(localized: "Pet", table: "Money")
    case "tent.fill": String(localized: "Outdoors", table: "Money")
    case "heart.fill": String(localized: "Something special", table: "Money")
    default: String(localized: "Goal", table: "Money")
    }
  }

  /// Whole percent, rounded down, so a goal never reads as further along than it is.
  static func percent(_ thousandths: Int, locale: Locale) -> String {
    (Double(thousandths / 10) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
  }

  static func saved(_ share: GoalShare, locale: Locale) -> String {
    String(localized: "\(percent(share.progressThousandths, locale: locale)) saved", table: "Money")
  }

  static func amounts(_ share: GoalShare, locale: Locale) -> String {
    let currency = share.goal.currency
    let filled = MoneyText.formatted(share.filledMinor, currency, locale: locale)
    let target = MoneyText.formatted(share.goal.targetMinor, currency, locale: locale)
    guard share.remainingMinor > 0 else { return String(localized: "\(filled) of \(target)", table: "Money") }
    return String(localized: "\(filled) of \(target), \(MoneyText.formatted(share.remainingMinor, currency, locale: locale)) to go", table: "Money")
  }

  /// What savings hold for the goal now, when its purchases already drew some of it.
  static func held(_ share: GoalShare, locale: Locale) -> String? {
    guard share.drawnMinor > 0 else { return nil }
    let currency = share.goal.currency
    return String(
      localized:
        "\(MoneyText.formatted(share.shareMinor, currency, locale: locale)) held for it now; \(MoneyText.formatted(share.drawnMinor, currency, locale: locale)) already spent on it",
      table: "Money")
  }

  static func targetDate(_ goal: SavingsGoalRecord, locale: Locale) -> String? {
    goal.targetDate.map { String(localized: "Target date \(MoneyDates.text($0, locale: locale))", table: "Money") }
  }

  /// The forecast line every state has, the plan's copy.
  static func forecast(
    _ forecast: GoalForecast, today: LocalDate, home: CurrencyCode, cause: (UUID) -> String?, category: (CategoryKey) -> String, locale: Locale
  ) -> String {
    self.forecast(
      forecast.state, eta: forecast.eta, target: forecast.need?.target, leverEta: forecast.lever?.eta, today: today, home: home, cause: cause,
      category: category, locale: locale)
  }

  /// `eta` is when the goal arrives at the pace, `target` its target date, `leverEta` when it would arrive with its lever.
  static func forecast(
    _ state: GoalForecastState, eta: LocalDate?, target: LocalDate?, leverEta: LocalDate?, today: LocalDate, home: CurrencyCode, cause: (UUID) -> String?,
    category: (CategoryKey) -> String, locale: Locale
  ) -> String {
    func money(_ minor: Int64) -> String { MoneyText.formatted(minor, home, locale: locale) }
    func month(_ day: LocalDate) -> String { MoneyDates.month(day, locale: locale) }
    switch state {
    case .onTrack(let eta):
      return String(localized: "On track for around \(month(eta)).", table: "Money")
    case .aheadOfTarget(let eta, let target):
      return String(localized: "Ahead of your date: around \(month(eta)), before \(MoneyDates.text(target, locale: locale)).", table: "Money")
    case .behind(let perMonth, let perDay):
      guard let target else {
        return String(localized: "It needs about \(money(perMonth)) more a month, about \(money(perDay)) a day.", table: "Money")
      }
      let date = MoneyDates.text(target, locale: locale)
      return String(localized: "To reach it by \(date), it needs about \(money(perMonth)) more a month, about \(money(perDay)) a day.", table: "Money")
    case .lever(let key, let monthsSooner):
      let share = (Double(SavingsRules.leverThousandths) / 1000).formatted(.percent.precision(.fractionLength(0)).locale(locale))
      let sooner = String(localized: "about \(monthsSooner) months", table: "Money")
      guard let eta = leverEta else {
        return String(localized: "Spending \(share) less on \(category(key)) could bring it \(sooner) sooner.", table: "Money")
      }
      return String(localized: "Spending \(share) less on \(category(key)) could bring it \(sooner) sooner, to around \(month(eta)).", table: "Money")
    case .noPace:
      return String(localized: "Nothing was left under budget in recent months, so there’s no estimate yet. The next month that is starts it moving.", table: "Money")
    case .calibrating(let monthsLeft) where monthsLeft > 0:
      let months = String(localized: "\(monthsLeft) more months", table: "Money")
      return String(localized: "An estimate comes once budgets have closed \(months).", table: "Money")
    case .calibrating:
      return String(localized: "An estimate comes once budgets have closed a few more months.", table: "Money")
    case .pushedBack(let days, let id):
      let later = String(localized: "about \(days) days", table: "Money")
      let eta = eta.map(month) ?? ""
      guard let title = cause(id) else {
        return String(localized: "A draw on savings this month moves it \(later) later, to around \(eta).", table: "Money")
      }
      return String(localized: "“\(title)” drew on savings this month, so it moves \(later) later, to around \(eta).", table: "Money")
    case .repaying(let owed):
      return String(localized: "Savings pay back \(money(owed)) first, then this goal starts filling.", table: "Money")
    case .reached(let buyFrom) where buyFrom <= today:
      return String(localized: "Reached. You can buy it whenever you’re ready.", table: "Money")
    case .reached(let buyFrom):
      return String(localized: "Reached. You can buy it from \(MoneyDates.text(buyFrom, locale: locale)), after its cooling-off.", table: "Money")
    }
  }

  /// What a goal with a target date needs to arrive on it, a month and a day.
  static func need(_ need: GoalTargetNeed, home: CurrencyCode, locale: Locale) -> String {
    let month = MoneyText.formatted(need.perMonthMinor, home, locale: locale)
    let day = MoneyText.formatted(need.perDayMinor, home, locale: locale)
    return String(localized: "By \(MoneyDates.text(need.target, locale: locale)): \(month) a month, about \(day) a day", table: "Money")
  }

  /// The estimate in a few words, for a chip read aloud.
  static func short(_ forecast: GoalForecast?, locale: Locale) -> String? {
    guard let forecast else { return nil }
    if case .reached = forecast.state { return String(localized: "reached", table: "Money") }
    return forecast.eta.map { String(localized: "around \(MoneyDates.month($0, locale: locale))", table: "Money") }
  }

  /// "New bike, 45% saved, around April 2027".
  static func accessibilityLabel(_ share: GoalShare, forecast: GoalForecast?, locale: Locale) -> String {
    [share.goal.name, saved(share, locale: locale), short(forecast, locale: locale)].compactMap(\.self).joined(separator: ", ")
  }

  static func state(_ goal: SavingsGoalRecord, home: CurrencyCode) -> String? {
    guard goal.currency == home else { return String(localized: "In \(goal.currency.code), so it doesn’t fill", table: "Money") }
    switch goal.state {
    case .known(.active): return nil
    case .known(.bought): return String(localized: "Bought", table: "Money")
    case .known(.abandoned): return String(localized: "Set aside", table: "Money")
    case .unknown: return String(localized: "Update Memoir to see this goal’s state", table: "Money")
    }
  }

  static func eligibility(_ eligibility: GoalRewardEligibility, home: CurrencyCode, locale: Locale) -> String {
    switch eligibility {
    case .eligible:
      return String(localized: "Earns a reward at each quarter of the way, and when it’s bought within its target.", table: "Money")
    case .targetBelowMinimum(let minimum):
      return String(localized: "Goals of at least \(MoneyText.formatted(minimum, home, locale: locale)) earn rewards.", table: "Money")
    case .homeWithoutLimit:
      return String(localized: "Goals earn rewards when Home had a monthly limit on the day they were made.", table: "Money")
    case .limitAwaitingRate:
      return String(localized: "Whether this goal earns rewards waits for an exchange rate for Home’s limit.", table: "Money")
    case .otherCurrency:
      return String(localized: "Goals in another currency than \(home.code) don’t earn rewards.", table: "Money")
    }
  }

  static func limit(_ maximum: Int) -> String {
    String(localized: "Up to \(maximum) goals fill at once, in the order you put them. Buy or set one aside to start another.", table: "Money")
  }

  static func notice(_ notice: GoalActionNotice) -> String {
    switch notice {
    case .bought(rewarded: true): String(localized: "Bought. Its rewards are on your hero.", table: "Money")
    case .bought(rewarded: false): String(localized: "Bought. What it didn’t use goes back to savings.", table: "Money")
    case .abandoned: String(localized: "Set aside. What it held goes back to savings for the other goals.", table: "Money")
    case .deleted: String(localized: "Deleted.", table: "Money")
    }
  }
}
