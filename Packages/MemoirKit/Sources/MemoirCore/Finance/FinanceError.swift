import Foundation
import ShadowCore
import ShadowStore

public enum FinanceError: ShadowError, Equatable, Hashable {
  case unknownCurrency(CurrencyCode)
  case currencyMismatch(CurrencyCode, CurrencyCode)
  case overflow
  case rateNotPositive(DecimalText)
  case rateOutOfRange(DecimalText)
  case negativeBudget(Int64)
  case unknownFrequency(String)
  case customIntervalNotPositive(Int)
  case billingDayOutOfRange(Int)
  case dateOutOfRange
  case subscriptionAbsent(UUID)
  /// The reference's `FIN_006` for the currency: an expense keeps the currency, rate, receipt and logging time of its first write.
  case expenseFieldFixed(String)
  case expenseExists(UUID)
  case refundExceedsAmount(refund: Int64, amount: Int64)
  case refundNotPositive(Int64)
  case nothingToRefund(UUID)
  case budgetAbsent(UUID)
  case budgetExists(UUID)
  case homeBudgetFixed
  case budgetFieldFixed(String)
  case budgetNameRequired
  case budgetLimitRequired
  case negativeLimit(Int64)
  case invalidTripDates
  case tripsOverlap(UUID)
  case tripLimitLocked
  case tripStartFixed
  case tripStartTooEarly(earliest: LocalDate)
  case limitChangedThisMonth
  case currencyTaken(CurrencyCode)
  case settingsAbsent
  case goalAbsent(UUID)
  case goalExists(UUID)
  case goalNameRequired
  case goalSymbolRequired
  case goalTargetNotPositive(Int64)
  case goalTargetDatePassed(earliest: LocalDate)
  case goalLimitReached(maximum: Int)
  case goalNotActive(UUID)
  case goalNotPurchased(UUID)
  case coolingOffNotMet(buyFrom: LocalDate)
  case savingsNotPositive(Int64)
  case savingsExceedsAmount(savings: Int64, amount: Int64)
  case notOneOff(thresholdMinor: Int64?)
  case savingsInsufficient(availableMinor: Int64)
  case savingsAwaitingRate
  /// Replay stopped at a command this build cannot read, so what it would reward cannot be known yet.
  case replayHalted
  case unreadable(EntityRef)
  case store(String)
  case recordWrite(String)

  public var code: String {
    switch self {
    case .unknownCurrency: "memoir_finance.unknown_currency"
    case .currencyMismatch: "memoir_finance.currency_mismatch"
    case .overflow: "memoir_finance.overflow"
    case .rateNotPositive: "memoir_finance.rate_not_positive"
    case .rateOutOfRange: "memoir_finance.rate_out_of_range"
    case .negativeBudget: "memoir_finance.negative_budget"
    case .unknownFrequency: "memoir_finance.unknown_frequency"
    case .customIntervalNotPositive: "memoir_finance.custom_interval_not_positive"
    case .billingDayOutOfRange: "memoir_finance.billing_day_out_of_range"
    case .dateOutOfRange: "memoir_finance.date_out_of_range"
    case .subscriptionAbsent: "memoir_finance.subscription_absent"
    case .expenseFieldFixed: "memoir_finance.expense_field_fixed"
    case .expenseExists: "memoir_finance.expense_exists"
    case .refundExceedsAmount: "memoir_finance.refund_exceeds_amount"
    case .refundNotPositive: "memoir_finance.refund_not_positive"
    case .nothingToRefund: "memoir_finance.nothing_to_refund"
    case .budgetAbsent: "memoir_finance.budget_absent"
    case .budgetExists: "memoir_finance.budget_exists"
    case .homeBudgetFixed: "memoir_finance.home_budget_fixed"
    case .budgetFieldFixed: "memoir_finance.budget_field_fixed"
    case .budgetNameRequired: "memoir_finance.budget_name_required"
    case .budgetLimitRequired: "memoir_finance.budget_limit_required"
    case .negativeLimit: "memoir_finance.negative_limit"
    case .invalidTripDates: "memoir_finance.invalid_trip_dates"
    case .tripsOverlap: "memoir_finance.trips_overlap"
    case .tripLimitLocked: "memoir_finance.trip_limit_locked"
    case .tripStartFixed: "memoir_finance.trip_start_fixed"
    case .tripStartTooEarly: "memoir_finance.trip_start_too_early"
    case .limitChangedThisMonth: "memoir_finance.limit_changed_this_month"
    case .currencyTaken: "memoir_finance.currency_taken"
    case .settingsAbsent: "memoir_finance.settings_absent"
    case .goalAbsent: "memoir_finance.goal_absent"
    case .goalExists: "memoir_finance.goal_exists"
    case .goalNameRequired: "memoir_finance.goal_name_required"
    case .goalSymbolRequired: "memoir_finance.goal_symbol_required"
    case .goalTargetNotPositive: "memoir_finance.goal_target_not_positive"
    case .goalTargetDatePassed: "memoir_finance.goal_target_date_passed"
    case .goalLimitReached: "memoir_finance.goal_limit_reached"
    case .goalNotActive: "memoir_finance.goal_not_active"
    case .goalNotPurchased: "memoir_finance.goal_not_purchased"
    case .coolingOffNotMet: "memoir_finance.cooling_off_not_met"
    case .savingsNotPositive: "memoir_finance.savings_not_positive"
    case .savingsExceedsAmount: "memoir_finance.savings_exceeds_amount"
    case .notOneOff: "memoir_finance.not_one_off"
    case .savingsInsufficient: "memoir_finance.savings_insufficient"
    case .savingsAwaitingRate: "memoir_finance.savings_awaiting_rate"
    case .replayHalted: "memoir_finance.replay_halted"
    case .unreadable: "memoir_finance.unreadable"
    case .store: "memoir_finance.store"
    case .recordWrite: "memoir_finance.record_write"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unknownCurrency(let code): "\(code) is not an ISO 4217 currency with minor units."
    case .currencyMismatch(let first, let second): "\(first) and \(second) amounts cannot be added without a conversion."
    case .overflow: "The amount does not fit in 64-bit minor units."
    case .rateNotPositive(let rate): "An exchange rate must be above zero, not \(rate)."
    case .rateOutOfRange(let rate):
      "The exchange rate \(rate) needs more than \(ExchangeRate.maximumScale) decimal places or 18 significant digits."
    case .negativeBudget(let amount): "A monthly budget is zero or more, not \(amount)."
    case .unknownFrequency(let frequency): "\"\(frequency)\" is not a billing frequency this version knows."
    case .customIntervalNotPositive(let days): "A custom billing interval is one day or more, not \(days)."
    case .billingDayOutOfRange(let day): "Billing day \(day) is not between 1 and 31."
    case .dateOutOfRange: "The date falls outside the years 0000 to 9999."
    case .subscriptionAbsent(let id): "Subscription \(id.lowercasedString) is not in the vault."
    case .expenseFieldFixed(let field): "An expense's \(field) cannot change after it is written; record a new expense instead."
    case .expenseExists(let id): "Expense \(id.lowercasedString) already exists."
    case .refundExceedsAmount(let refund, let amount): "A refund of \(refund) is more than the \(amount) the expense still holds."
    case .refundNotPositive(let refund): "A refund is above zero, not \(refund)."
    case .nothingToRefund(let id): "Expense \(id.lowercasedString) has nothing left to refund."
    case .budgetAbsent(let id): "Budget \(id.lowercasedString) is not in the vault."
    case .budgetExists(let id): "Budget \(id.lowercasedString) already exists."
    case .homeBudgetFixed: "Home is always kept, monthly and in the currency it was created in; it cannot be deleted, renamed or moved."
    case .budgetFieldFixed(let field): "A budget's \(field) cannot change after it is created."
    case .budgetNameRequired: "A budget other than Home needs a name."
    case .budgetLimitRequired: "A budget needs a limit."
    case .negativeLimit(let amount): "A budget's limit and one-off threshold are zero or more, not \(amount)."
    case .invalidTripDates: "A trip ends on or after the day it starts."
    case .tripsOverlap(let id): "The trip shares a day with trip \(id.lowercasedString)."
    case .tripLimitLocked: "A trip's limit cannot be raised once the trip has started."
    case .tripStartFixed: "A trip that has started keeps its first day."
    case .tripStartTooEarly(let earliest): "A trip starts on \(earliest) or later."
    case .limitChangedThisMonth: "This month's limit has already changed; a raise waits until next month."
    case .currencyTaken(let code): "There is already a monthly budget in \(code)."
    case .settingsAbsent: "The vault has no account settings yet, so it has no home currency."
    case .goalAbsent(let id): "Savings goal \(id.lowercasedString) is not in the vault."
    case .goalExists(let id): "Savings goal \(id.lowercasedString) already exists."
    case .goalNameRequired: "A savings goal needs a name."
    case .goalSymbolRequired: "A savings goal needs a symbol."
    case .goalTargetNotPositive(let amount): "A savings goal's target is above zero, not \(amount)."
    case .goalTargetDatePassed(let earliest): "A savings goal's target date is \(earliest) or later."
    case .goalLimitReached(let maximum): "At most \(maximum) savings goals can be active at once."
    case .goalNotActive(let id): "Savings goal \(id.lowercasedString) is no longer active."
    case .goalNotPurchased(let id): "No expense buys savings goal \(id.lowercasedString) yet."
    case .coolingOffNotMet(let buyFrom): "A savings goal can be bought from \(buyFrom), once its cooling-off has passed."
    case .savingsNotPositive(let amount): "The part paid from savings is above zero, not \(amount)."
    case .savingsExceedsAmount(let savings, let amount): "\(savings) from savings is more than the expense's \(amount)."
    case .notOneOff(let threshold?): "Only a one-off of at least \(threshold) can be paid from savings."
    case .notOneOff(nil): "Only a one-off can be paid from savings, and this budget has no one-off threshold yet."
    case .savingsInsufficient(let available): "Savings can cover at most \(available) now."
    case .savingsAwaitingRate: "The amount paid from savings waits for an exchange rate."
    case .replayHalted: "This build cannot read every command in the vault; update the app to finish this."
    case .unreadable(let ref): "\(ref.kind)/\(ref.key) cannot be read."
    case .store(let reason): "The store failed: \(reason)"
    case .recordWrite(let reason): "The record write was refused: \(reason)"
    }
  }

  init(_ error: StoreError) {
    if case .aborted(let inner as FinanceError) = error {
      self = inner
    } else {
      self = .store(error.description)
    }
  }

  init(_ error: MemoirRecordError) {
    switch error {
    case .store(let inner): self.init(inner)
    case .unreadable(let ref, _): self = .unreadable(ref)
    default: self = .recordWrite(error.description)
    }
  }
}
