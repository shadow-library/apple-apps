import Foundation
import MemoirCore

/// The values of a reading this form can take: the total in a currency it offers with that currency's places, a date not after the latest it allows,
/// a category it lists. The total and its currency go together, so the form never switches currency without the amount; the rest is left out rather
/// than forced in.
nonisolated struct ReceiptSuggestion: Sendable, Equatable {
  let amount: MoneyAmount?
  /// The currency the receipt names when this expense cannot be in it; its total is then left out.
  let unusableCurrency: CurrencyCode?
  let occurredOn: LocalDate?
  let merchant: String?
  let category: CategoryKey?
  /// The reading is unsure, or its total could not be used.
  let needsReview: Bool

  var isEmpty: Bool { amount == nil && occurredOn == nil && merchant == nil && category == nil }
}

extension ExpenseForm {
  /// The model writes amounts with a full stop and no grouping, whatever the owner's locale.
  private nonisolated static let readingFormat = AmountFormat(decimalSeparator: ".", groupingSeparator: nil)

  func suggestion(from reading: ReceiptReading) -> ReceiptSuggestion {
    let target: CurrencyCode? = reading.currency.map { named in named == currency || (canChangeCurrency && currencies.contains(named)) ? named : nil } ?? currency
    let amount = target.flatMap { code in
      (try? AmountInput.minorUnits(reading.amount, currency: code, format: Self.readingFormat)).map { MoneyAmount(amountMinor: $0, currency: code) }
    }
    return ReceiptSuggestion(
      amount: amount, unusableCurrency: target == nil ? reading.currency : nil, occurredOn: reading.date.flatMap { $0 <= latestDate ? $0 : nil },
      merchant: reading.merchant, category: reading.category.flatMap { key in categories.contains { $0.key == key } ? key : nil },
      needsReview: reading.needsReview || amount == nil)
  }

  /// Fills the form from the reading; the owner still saves it themselves, and the expense is then saved as scanned.
  func use(_ suggestion: ReceiptSuggestion) {
    if let amount = suggestion.amount {
      select(amount.currency)
      amountText = MoneyText.editable(amount.amountMinor, amount.currency, format: format)
    }
    if let date = suggestion.occurredOn { occurredOn = date }
    if let merchant = suggestion.merchant { self.merchant = merchant }
    if let category = suggestion.category { self.category = category }
    receipt?.scanUsed()
    edited()
  }
}
