import Foundation
import ShadowCore

/// The separators an amount is typed with, from the owner's locale.
public struct AmountFormat: Sendable, Hashable {
  public let decimalSeparator: Character
  public let groupingSeparator: Character?

  public init(decimalSeparator: Character, groupingSeparator: Character?) {
    self.decimalSeparator = decimalSeparator
    self.groupingSeparator = groupingSeparator == decimalSeparator ? nil : groupingSeparator.map(Self.normalized)
  }

  public init(locale: Locale) {
    self.init(
      decimalSeparator: Self.single(locale.decimalSeparator) ?? ".", groupingSeparator: Self.single(locale.groupingSeparator))
  }

  /// Any space stands for a space-like grouping mark (French uses a narrow no-break space), and a straight apostrophe for a curly one (Swiss).
  static func normalized(_ character: Character) -> Character {
    if character.isWhitespace { return " " }
    if character == "\u{2019}" { return "'" }
    return character
  }

  private static func single(_ text: String?) -> Character? {
    guard let text, text.count == 1 else { return nil }
    return text.first
  }
}

public enum AmountInputRefusal: ShadowError, Equatable {
  case empty
  case negative
  case unexpectedCharacter(Character)
  case repeatedDecimalSeparator
  case misplacedGrouping
  case tooPrecise(allowedPlaces: Int)
  case outOfRange
  case unknownCurrency(CurrencyCode)

  public var code: String {
    switch self {
    case .empty: "memoir_amount.empty"
    case .negative: "memoir_amount.negative"
    case .unexpectedCharacter: "memoir_amount.unexpected_character"
    case .repeatedDecimalSeparator: "memoir_amount.repeated_decimal_separator"
    case .misplacedGrouping: "memoir_amount.misplaced_grouping"
    case .tooPrecise: "memoir_amount.too_precise"
    case .outOfRange: "memoir_amount.out_of_range"
    case .unknownCurrency: "memoir_amount.unknown_currency"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .empty: "The amount has no digits."
    case .negative: "An amount is zero or more."
    case .unexpectedCharacter(let character): "\"\(character)\" cannot appear in an amount."
    case .repeatedDecimalSeparator: "The amount has more than one decimal separator."
    case .misplacedGrouping: "The digit grouping does not fall every two or three digits before the decimal separator."
    case .tooPrecise(let places): "The currency has \(places) decimal places, and the amount has more that are not zero."
    case .outOfRange: "The amount does not fit in 64-bit minor units."
    case .unknownCurrency(let currency): "\(currency) is not an ISO 4217 currency with minor units."
    }
  }
}

/// Reads what the owner typed into minor units, exactly. memoir-web's `parseAmountToMinor` (`lib/data/finance.rules.ts:61`) guesses the decimal
/// separator (the last separator, unless a lone one is followed by three digits) and rounds through a binary float; here the separator comes from the
/// owner's locale and nothing is guessed or rounded:
/// - the locale's grouping separator may only fall between digits before the decimal separator, with three digits after the last one and two or three
///   between earlier ones (so `1,00,000` is read but `1,5` in English is refused rather than read as 15);
/// - digits past the currency's ISO 4217 exponent must be zeros (`12.50` JPY is refused, `12.00` JPY is 12);
/// - a minus sign is refused, and anything other than digits, the two separators and surrounding spaces is refused.
public enum AmountInput {
  public static func minorUnits(_ text: String, currency: CurrencyCode, format: AmountFormat) throws(AmountInputRefusal) -> Int64 {
    let exponent: Int
    do throws(FinanceError) {
      exponent = try ISO4217.exponent(of: currency)
    } catch {
      throw .unknownCurrency(currency)
    }
    let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    var groups: [[Int]] = [[]]
    var fraction: [Int]?
    for character in characters {
      if let digit = digit(character) {
        if fraction != nil { fraction?.append(digit) } else { groups[groups.count - 1].append(digit) }
        continue
      }
      if character == "-" || character == "\u{2212}" { throw .negative }
      if character == format.decimalSeparator {
        guard fraction == nil else { throw .repeatedDecimalSeparator }
        fraction = []
        continue
      }
      if let grouping = format.groupingSeparator, AmountFormat.normalized(character) == grouping {
        guard fraction == nil else { throw .misplacedGrouping }
        groups.append([])
        continue
      }
      throw .unexpectedCharacter(character)
    }
    guard groups.contains(where: { !$0.isEmpty }) || !(fraction ?? []).isEmpty else { throw .empty }
    try checkGrouping(groups)
    let fractionDigits = fraction ?? []
    guard fractionDigits.dropFirst(exponent).allSatisfy({ $0 == 0 }) else { throw .tooPrecise(allowedPlaces: exponent) }
    let kept = Array(fractionDigits.prefix(exponent)) + Array(repeating: 0, count: max(0, exponent - fractionDigits.count))
    var minor: Int64 = 0
    for digit in groups.joined() + kept {
      let (shifted, overflow) = minor.multipliedReportingOverflow(by: 10)
      let (sum, carry) = shifted.addingReportingOverflow(Int64(digit))
      guard !overflow, !carry else { throw .outOfRange }
      minor = sum
    }
    return minor
  }

  private static func checkGrouping(_ groups: [[Int]]) throws(AmountInputRefusal) {
    guard groups.count > 1 else { return }
    guard let first = groups.first, let last = groups.last, (1...3).contains(first.count), last.count == 3 else { throw .misplacedGrouping }
    guard groups.dropFirst().dropLast().allSatisfy({ (2...3).contains($0.count) }) else { throw .misplacedGrouping }
  }

  private static func digit(_ character: Character) -> Int? {
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, scalar.properties.numericType == .decimal,
      let value = character.wholeNumberValue, (0...9).contains(value)
    else { return nil }
    return value
  }
}
