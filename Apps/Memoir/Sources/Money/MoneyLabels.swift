import Foundation
import MemoirCore

/// memoir-web's finance copy (`lib/data/finance.types.ts`, `finance.rules.ts`, `finance.provider.ts`), localized in `Money.xcstrings`.
nonisolated enum MoneyLabels {
  static func categoryName(_ key: CategoryKey, label: String? = nil) -> String {
    switch key.key {
    case "food": String(localized: "Food", table: "Money")
    case "groceries": String(localized: "Groceries", table: "Money")
    case "transport": String(localized: "Transport", table: "Money")
    case "bills": String(localized: "Bills", table: "Money")
    case "health": String(localized: "Health", table: "Money")
    case "shopping": String(localized: "Shopping", table: "Money")
    case "home": String(localized: "Home", table: "Money")
    case "subs": String(localized: "Subscriptions", table: "Money")
    case "uncat": String(localized: "Uncategorised", table: "Money")
    default: label ?? key.key
    }
  }

  static func categoryHint(_ key: CategoryKey) -> String? {
    switch key.key {
    case "food": String(localized: "Coffee, eating out, takeaway", table: "Money")
    case "groceries": String(localized: "The weekly shop", table: "Money")
    case "transport": String(localized: "Tram, fuel, parking", table: "Money")
    case "bills": String(localized: "Power, water, phone", table: "Money")
    case "health": String(localized: "Gym, physio, kit", table: "Money")
    case "shopping": String(localized: "Clothes, books, gifts", table: "Money")
    case "home": String(localized: "Rent, repairs, furniture", table: "Money")
    case "subs": String(localized: "Managed on the Subscriptions screen", table: "Money")
    case "uncat": String(localized: "Waiting for a category", table: "Money")
    default: nil
    }
  }

  static func categorySymbol(_ key: CategoryKey) -> String {
    switch key.key {
    case "food": "cup.and.saucer"
    case "groceries": "cart"
    case "transport": "tram"
    case "bills": "doc.text"
    case "health": "cross.case"
    case "shopping": "bag"
    case "home": "house"
    case "subs": "repeat"
    default: "questionmark"
    }
  }

  /// The label a category record is created with, memoir-web's built-in name, which the record keeps as data; the app names built-ins itself.
  static func storedLabel(_ key: CategoryKey) -> String {
    switch key.key {
    case "food": "Food"
    case "groceries": "Groceries"
    case "transport": "Transport"
    case "bills": "Bills"
    case "health": "Health"
    case "shopping": "Shopping"
    case "home": "Home"
    case "subs": "Subscriptions"
    case "uncat": "Uncategorised"
    default: key.key
    }
  }

  static func rangeTitle(_ range: FinanceRange) -> String {
    switch range {
    case .week: String(localized: "Week", table: "Money")
    case .month: String(localized: "Month", table: "Money")
    case .year: String(localized: "Year", table: "Money")
    }
  }

  static func spentTitle(_ range: FinanceRange) -> String {
    switch range {
    case .week: String(localized: "Spent this week", table: "Money")
    case .month: String(localized: "Spent this month", table: "Money")
    case .year: String(localized: "Spent this year", table: "Money")
    }
  }

  static func periodTitle(_ range: FinanceRange) -> String {
    switch range {
    case .week: String(localized: "This week", table: "Money")
    case .month: String(localized: "This month", table: "Money")
    case .year: String(localized: "This year", table: "Money")
    }
  }

  /// memoir-web `spendComparison` (`features/finance/expenses-screen.tsx`).
  static func comparison(_ spend: RangeSpend) -> String {
    guard let delta = spend.delta else { return String(localized: "Nothing earlier to compare with yet", table: "Money") }
    let percent = MoneyText.percent(delta)
    let percentText = percent.formatted(.percent)
    switch (spend.range, percent == 0, delta.numerator < 0) {
    case (.week, true, _): return String(localized: "About the same as the same days last week", table: "Money")
    case (.month, true, _): return String(localized: "About the same as the same days last month", table: "Money")
    case (.year, true, _): return String(localized: "About the same as the same stretch last year", table: "Money")
    case (.week, false, true): return String(localized: "\(percentText) less than the same days last week", table: "Money")
    case (.week, false, false): return String(localized: "\(percentText) more than the same days last week", table: "Money")
    case (.month, false, true): return String(localized: "\(percentText) less than the same days last month", table: "Money")
    case (.month, false, false): return String(localized: "\(percentText) more than the same days last month", table: "Money")
    case (.year, false, true): return String(localized: "\(percentText) less than the same stretch last year", table: "Money")
    case (.year, false, false): return String(localized: "\(percentText) more than the same stretch last year", table: "Money")
    }
  }

  static func frequency(_ frequency: SubscriptionFrequency) -> String {
    switch frequency {
    case .weekly: String(localized: "Weekly", table: "Money")
    case .monthly: String(localized: "Monthly", table: "Money")
    case .quarterly: String(localized: "Quarterly", table: "Money")
    case .yearly: String(localized: "Yearly", table: "Money")
    case .custom: String(localized: "Custom cycle", table: "Money")
    }
  }

  static func reminderLead(_ lead: SubscriptionReminderLead) -> String {
    switch lead {
    case .onDay: String(localized: "On the day", table: "Money")
    case .oneDay: String(localized: "1 day before", table: "Money")
    case .twoDays: String(localized: "2 days before", table: "Money")
    case .threeDays: String(localized: "3 days before", table: "Money")
    case .oneWeek: String(localized: "1 week before", table: "Money")
    }
  }

  /// memoir-web `DUE_STATE_LABELS`.
  static func dueState(_ state: SubscriptionDueState) -> String? {
    switch state {
    case .none: nil
    case .upcoming: String(localized: "Renews soon", table: "Money")
    case .due: String(localized: "Renews today", table: "Money")
    case .overdue: String(localized: "Waiting to be confirmed", table: "Money")
    }
  }

  /// What the amount field says about an amount `AmountInput` refused.
  static func amountIssue(_ refusal: AmountInputRefusal, currency: CurrencyCode, format: AmountFormat) -> String {
    switch refusal {
    case .empty: String(localized: "Enter an amount, for example \(MoneyText.example(currency, format: format))", table: "Money")
    case .negative: String(localized: "Enter an amount of zero or more.", table: "Money")
    case .unexpectedCharacter(let character): String(localized: "“\(String(character))” can’t be part of an amount.", table: "Money")
    case .repeatedDecimalSeparator: String(localized: "An amount has only one decimal separator.", table: "Money")
    case .misplacedGrouping: String(localized: "Check the digit grouping: the last group before the decimal separator has three digits.", table: "Money")
    case .tooPrecise(let places) where places == 0: String(localized: "\(currency.code) amounts have no decimal places.", table: "Money")
    case .tooPrecise(let places): String(localized: "\(currency.code) amounts have at most \(places) decimal places.", table: "Money")
    case .outOfRange: String(localized: "That amount is too large.", table: "Money")
    case .unknownCurrency: String(localized: "\(currency.code) can’t be used for an amount.", table: "Money")
    }
  }

  static func rateIssue(_ refusal: RateInputRefusal, format: AmountFormat) -> String {
    let example = "0\(format.decimalSeparator)0934"
    return switch refusal {
    case .unreadable(.negative), .notPositive: String(localized: "Enter a rate above zero.", table: "Money")
    case .unreadable(.unexpectedCharacter(let character)): String(localized: "“\(String(character))” can’t be part of a rate.", table: "Money")
    case .unreadable(.repeatedDecimalSeparator): String(localized: "A rate has only one decimal separator.", table: "Money")
    case .tooPrecise(let places): String(localized: "A rate has at most \(places) decimal places.", table: "Money")
    case .unreadable, .outOfRange: String(localized: "Enter a rate such as \(example).", table: "Money")
    }
  }
}
