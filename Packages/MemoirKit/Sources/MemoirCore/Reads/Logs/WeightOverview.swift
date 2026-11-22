import ShadowStore

public enum WeightUnit: String, Sendable, CaseIterable {
  case kilograms
  case pounds
}

/// Converts between kilograms and pounds through the international pound, exactly 0.45359237 kg, and rounds the result half up (toward positive
/// infinity) to `places` decimal places, one by default as memoir-web shows weights. memoir-web multiplies by the truncated factor 2.20462262
/// (`lib/data/quick-logs.rules.ts:285-291`), which can differ in the last place.
public enum WeightConversion {
  public static let defaultPlaces = 1

  private static let gramsPerPoundNumerator: Int128 = 45_359_237
  private static let gramsPerPoundDenominator: Int128 = 100_000_000

  public static func convert(_ value: DecimalText, from source: WeightUnit, to target: WeightUnit, places: Int = defaultPlaces) -> DecimalText? {
    guard let exact = ExactDecimal(value), let denominator = ExactDecimal.power(exact.scale) else { return nil }
    let places = max(0, min(places, ExactDecimal.maximumScale))
    let ratio: (numerator: Int128, denominator: Int128)? =
      switch (source, target) {
      case (.kilograms, .kilograms), (.pounds, .pounds): (exact.significand, denominator)
      case (.kilograms, .pounds): Self.scaled(exact.significand, denominator, by: gramsPerPoundDenominator, over: gramsPerPoundNumerator)
      case (.pounds, .kilograms): Self.scaled(exact.significand, denominator, by: gramsPerPoundNumerator, over: gramsPerPoundDenominator)
      }
    guard let ratio else { return nil }
    return ExactDecimal.rounding(ratio.numerator, over: ratio.denominator, places: places)?.text
  }

  private static func scaled(_ numerator: Int128, _ denominator: Int128, by factor: Int128, over divisor: Int128) -> (numerator: Int128, denominator: Int128)? {
    guard let top = Exact.multiplied(numerator, factor), let bottom = Exact.multiplied(denominator, divisor) else { return nil }
    return (top, bottom)
  }
}

/// memoir-web `SyncedQuickLogProvider.weight` (`lib/sync/synced-quick-log-provider.ts:255-273`). Health class: read only from the restricted store.
public struct WeightOverview: Sendable, Equatable {
  public static let heldClass = SyncClass.health
  public static let averageDays = 7
  public static let trendDays = 90
  /// memoir-web `WEIGHT_RANGE_KG` (`quick-logs.rules.ts:48`).
  public static let acceptedKilograms = 30...250

  public let today: WeightRecord?
  /// Newest first.
  public let entries: [WeightRecord]
  /// The last 90 days' entries, oldest first.
  public let trend: [WeightRecord]
  /// The exact mean of the last seven days' entries; `nil` without one.
  public let sevenDayAverage: Fraction?
  /// The newest entry of the last 90 days less the oldest, exactly; `nil` with fewer than two.
  public let ninetyDayChange: DecimalText?
  public let ninetyDayStart: DecimalText?
  public let lightest: DecimalText?
  public let heaviest: DecimalText?
  public let unreadable: Int

  static func make(_ weights: [WeightRecord], unreadable: Int, today: LocalDate) -> WeightOverview {
    let entries = weights.sorted { $0.date > $1.date }
    let recent = entries.filter { $0.date <= today && today.days(since: $0.date) < trendDays }
    let week = recent.filter { today.days(since: $0.date) < averageDays }
    let newest = recent.first
    let start = recent.count >= 2 ? recent.last : nil
    let sorted = recent.map(\.kilograms).sorted()
    return WeightOverview(
      today: entries.first { $0.date == today }, entries: entries, trend: Array(recent.reversed()), sevenDayAverage: DecimalText.mean(week.map(\.kilograms)),
      ninetyDayChange: start.flatMap { start in newest?.kilograms.minus(start.kilograms) }, ninetyDayStart: start?.kilograms, lightest: sorted.first,
      heaviest: sorted.last, unreadable: unreadable)
  }

  /// Whether a weight in kilograms lies within memoir-web's accepted range.
  public static func isAccepted(_ kilograms: DecimalText) -> Bool {
    guard let exact = ExactDecimal(kilograms) else { return false }
    return ExactDecimal(acceptedKilograms.lowerBound) <= exact && exact <= ExactDecimal(acceptedKilograms.upperBound)
  }
}
