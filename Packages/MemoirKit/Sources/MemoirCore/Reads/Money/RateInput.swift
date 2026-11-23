import Foundation
import ShadowCore

public enum RateInputRefusal: ShadowError, Equatable {
  case unreadable(AmountInputRefusal)
  case notPositive
  case tooPrecise(allowedPlaces: Int)
  case outOfRange

  public var code: String {
    switch self {
    case .unreadable(let refusal): refusal.code
    case .notPositive: "memoir_rate_input.not_positive"
    case .tooPrecise: "memoir_rate_input.too_precise"
    case .outOfRange: "memoir_rate_input.out_of_range"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unreadable(let refusal): refusal.errorDescription
    case .notPositive: "An exchange rate is above zero."
    case .tooPrecise(let places): "An exchange rate has at most \(places) decimal places that are not zero."
    case .outOfRange: "The exchange rate has more digits than a rate can hold."
    }
  }
}

/// Reads a rate the owner typed, exactly, with the separators of their locale and the grouping rules of ``AmountInput``. A rate keeps at most the
/// eight places the reference stores (``ExchangeRate/storedScale``); more places that are not zero are refused rather than rounded.
public enum RateInput {
  public static func rate(_ text: String, format: AmountFormat) throws(RateInputRefusal) -> ExchangeRate {
    let typed: AmountInput.TypedDigits
    do throws(AmountInputRefusal) {
      typed = try AmountInput.digits(text, format: format)
    } catch {
      throw .unreadable(error)
    }
    var fraction = typed.fraction
    while fraction.last == 0 { fraction.removeLast() }
    guard fraction.count <= ExchangeRate.storedScale else { throw .tooPrecise(allowedPlaces: ExchangeRate.storedScale) }
    let whole = typed.whole.drop { $0 == 0 }
    let wholeText = whole.isEmpty ? "0" : whole.map(String.init).joined()
    let canonical = fraction.isEmpty ? wholeText : "\(wholeText).\(fraction.map(String.init).joined())"
    guard let decimal = DecimalText(canonical) else { throw .outOfRange }
    do throws(FinanceError) {
      return try ExchangeRate(decimal)
    } catch {
      if case .rateNotPositive = error { throw .notPositive }
      throw .outOfRange
    }
  }
}
