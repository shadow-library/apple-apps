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
