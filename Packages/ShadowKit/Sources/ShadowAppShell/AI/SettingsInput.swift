import Foundation
import ShadowAI

nonisolated enum SpendCapIssue: Error, Equatable {
  case invalid
  case notPositive
  case tooLarge
  case dailyAboveMonthly
}

nonisolated enum SpendCapInput {
  static let maximumUSD: Decimal = 1_000_000
  private static let fractionDigitLimit = 4

  static func parse(_ text: String, locale: Locale = .current) -> Result<Cost?, SpendCapIssue> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .success(nil) }
    let separator = locale.decimalSeparator?.first ?? "."
    let parts = trimmed.split(separator: separator, omittingEmptySubsequences: false)
    guard parts.count <= 2, parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }), trimmed.contains(where: { ("0"..."9").contains($0) }) else {
      return .failure(.invalid)
    }
    guard parts.count == 1 || parts[1].count <= fractionDigitLimit else { return .failure(.invalid) }
    let normalised = parts.map(String.init).joined(separator: ".")
    guard let amount = Decimal(string: normalised, locale: Locale(identifier: "en_US_POSIX")) else { return .failure(.invalid) }
    guard amount > 0 else { return .failure(.notPositive) }
    guard amount <= maximumUSD else { return .failure(.tooLarge) }
    return .success(Cost(nanoUSD: NSDecimalNumber(decimal: amount * Decimal(Cost.nanoUSDPerUSD)).int64Value))
  }

  static func text(for cost: Cost?, locale: Locale = .current) -> String {
    guard let cost else { return "" }
    let dollars = Decimal(cost.nanoUSD) / Decimal(Cost.nanoUSDPerUSD)
    return dollars.formatted(.number.grouping(.never).precision(.fractionLength(0...fractionDigitLimit)).locale(locale))
  }
}

nonisolated enum ModelIdentifierInput {
  static let lengthLimit = 200

  static func parse(_ text: String) -> Result<String?, ModelIdentifierIssue> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .success(nil) }
    guard trimmed.count <= lengthLimit, !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
      return .failure(.invalid)
    }
    return .success(trimmed)
  }
}

nonisolated enum ModelIdentifierIssue: Error, Equatable {
  case invalid
}
