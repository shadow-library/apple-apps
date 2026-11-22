import Foundation
import MemoirCore

nonisolated enum DecimalInputProblem: Error, Equatable, Sendable {
  case empty
  case notANumber
  case negative
}

/// Reads what the owner typed as an exact decimal: digits with at most one of the locale's decimal separators and nothing else, so nothing is guessed;
/// a grouping separator, or a full stop where the locale writes a comma, is refused rather than read one way or the other.
nonisolated enum DecimalInput {
  static func parse(_ input: String, locale: Locale = .current) -> Result<DecimalText, DecimalInputProblem> {
    let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !typed.isEmpty else { return .failure(.empty) }
    let separator = locale.decimalSeparator ?? "."
    var negative = false
    var whole = ""
    var fraction: String?
    for (offset, character) in typed.enumerated() {
      if offset == 0, character == "-" || character == "−" {
        negative = true
        continue
      }
      if String(character) == separator {
        guard fraction == nil else { return .failure(.notANumber) }
        fraction = ""
        continue
      }
      guard character.isASCII, character.isWholeNumber else { return .failure(.notANumber) }
      if fraction == nil { whole.append(character) } else { fraction?.append(character) }
    }
    guard !whole.isEmpty || !(fraction ?? "").isEmpty else { return .failure(.notANumber) }
    guard let text = canonical(whole: whole, fraction: fraction ?? "") else { return .failure(.notANumber) }
    if negative, text.text != "0" { return .failure(.negative) }
    return .success(text)
  }

  /// "7.5" or "7,5": a sample the owner can type, with the locale's decimal separator.
  static func example(whole: Int, fraction: Int, locale: Locale = .current) -> String {
    "\(whole)\(locale.decimalSeparator ?? ".")\(fraction)"
  }

  /// The value as the owner would type it back, with the locale's decimal separator.
  static func text(_ value: DecimalText, locale: Locale = .current) -> String {
    value.text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
  }

  /// The value with its decimal point moved `places` to the right, exactly: litres to millilitres is three places.
  static func shifted(_ value: DecimalText, by places: Int) -> DecimalText? {
    let parts = value.text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let wholePart = parts.first, !value.text.hasPrefix("-") else { return nil }
    let whole = String(wholePart)
    let fraction = parts.count == 2 ? String(parts[1]) : ""
    if places >= 0 {
      let padded = fraction.padding(toLength: max(fraction.count, places), withPad: "0", startingAt: 0)
      return canonical(whole: whole + padded.prefix(places), fraction: String(padded.dropFirst(places)))
    }
    let shift = -places
    let paddedWhole = String(repeating: "0", count: max(0, shift - whole.count)) + whole
    return canonical(whole: String(paddedWhole.dropLast(shift)), fraction: String(paddedWhole.suffix(shift)) + fraction)
  }

  private static func canonical(whole: String, fraction: String) -> DecimalText? {
    let trimmedWhole = whole.drop { $0 == "0" }
    var trimmedFraction = Substring(fraction)
    while trimmedFraction.last == "0" { trimmedFraction = trimmedFraction.dropLast() }
    let wholeText = trimmedWhole.isEmpty ? "0" : String(trimmedWhole)
    return DecimalText(trimmedFraction.isEmpty ? wholeText : "\(wholeText).\(trimmedFraction)")
  }
}
