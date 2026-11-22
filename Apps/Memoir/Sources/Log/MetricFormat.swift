import Foundation
import MemoirCore

/// How a metric's values are shown and typed (`metricDisplay`, `metricInputValue`, `readMetricEntry` in `quick-logs.rules.ts`). Water is kept in
/// millilitres and shown and typed in litres; a duration is kept in whole minutes and typed in hours.
nonisolated enum MetricFormat {
  static func name(_ metric: MetricDescriptor) -> String {
    metric.builtin.map(name) ?? metric.name
  }

  static func name(_ builtin: BuiltinMetric) -> String {
    switch builtin {
    case .steps: String(localized: "Steps", table: "Log")
    case .activeEnergy: String(localized: "Calories burned", table: "Log")
    case .workoutMinutes: String(localized: "Workout minutes", table: "Log")
    case .weight: String(localized: "Weight", table: "Log")
    case .restingHeartRate: String(localized: "Resting heart rate", table: "Log")
    case .sleep: String(localized: "Sleep duration", table: "Log")
    case .waistCircumference: String(localized: "Waist circumference", table: "Log")
    case .water: String(localized: "Water", table: "Log")
    }
  }

  /// The unit beside the field the owner types in.
  static func inputUnit(_ metric: MetricDescriptor) -> String? {
    if metric.builtin == .water { return String(localized: "L", table: "Log") }
    if metric.valueType == .known(.duration) { return String(localized: "h", table: "Log") }
    return unit(metric)
  }

  static func unit(_ metric: MetricDescriptor) -> String? {
    switch metric.builtin {
    case .steps: String(localized: "steps", table: "Log")
    case .activeEnergy: String(localized: "kcal", table: "Log")
    case .weight: String(localized: "kg", table: "Log")
    case .restingHeartRate: String(localized: "bpm", table: "Log")
    case .waistCircumference: String(localized: "cm", table: "Log")
    case .water: String(localized: "ml", table: "Log")
    case .workoutMinutes, .sleep: String(localized: "min", table: "Log")
    case nil: metric.unit.flatMap { $0.isEmpty ? nil : $0 }
    }
  }

  static func value(_ value: DecimalText, of metric: MetricDescriptor) -> String {
    if metric.builtin == .water { return water(value) }
    if metric.valueType == .known(.duration), let minutes = LogFormat.decimal(value) {
      let seconds = NSDecimalNumber(decimal: minutes * 60).int64Value
      return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
    let digits = metric.valueType == .known(.count) ? 0...0 : 0...2
    let number = LogFormat.number(value, fractionDigits: digits)
    guard let unit = unit(metric) else { return number }
    return String(localized: "\(number) \(unit)", table: "Log")
  }

  /// Under a litre in millilitres, else in litres with one or two places.
  static func water(_ millilitres: DecimalText) -> String {
    guard let value = LogFormat.decimal(millilitres) else { return millilitres.text }
    guard value >= 1000 else { return String(localized: "\(value.formatted(.number.precision(.fractionLength(0)))) ml", table: "Log") }
    return String(localized: "\((value / 1000).formatted(.number.precision(.fractionLength(1...2)))) L", table: "Log")
  }

  /// The stored value as the owner would type it back, every millilitre and minute kept.
  static func input(_ value: DecimalText, of metric: MetricDescriptor, locale: Locale = .current) -> String {
    if metric.builtin == .water, let litres = DecimalInput.shifted(value, by: -3) { return DecimalInput.text(litres, locale: locale) }
    if metric.valueType == .known(.duration), let minutes = LogFormat.decimal(value) {
      return (minutes / 60).formatted(.number.precision(.fractionLength(0...3)).grouping(.never).locale(locale))
    }
    return DecimalInput.text(value, locale: locale)
  }

  /// What the owner typed, in the stored unit; a blank field stays blank rather than meaning zero.
  static func stored(_ input: String, for metric: MetricDescriptor, locale: Locale = .current) -> Result<DecimalText, MetricEntryProblem> {
    let typed: DecimalText
    switch DecimalInput.parse(input, locale: locale) {
    case .failure(.empty): return .failure(.empty)
    case .failure(.negative): return .failure(.negative)
    case .failure(.notANumber): return .failure(.notANumber)
    case .success(let value): typed = value
    }
    if metric.builtin == .water { return DecimalInput.shifted(typed, by: 3).map(Result.success) ?? .failure(.notANumber) }
    if metric.valueType == .known(.duration) {
      guard let hours = LogFormat.decimal(typed) else { return .failure(.notANumber) }
      var minutes = hours * 60
      var rounded = Decimal()
      NSDecimalRound(&rounded, &minutes, 0, .plain)
      return DecimalText(NSDecimalNumber(decimal: rounded).stringValue).map(Result.success) ?? .failure(.notANumber)
    }
    if metric.valueType == .known(.count), typed.text.contains(".") { return .failure(.notWhole) }
    return .success(typed)
  }
}

nonisolated enum MetricEntryProblem: Error, Equatable, Sendable {
  case empty
  case notANumber
  case negative
  case notWhole

  func message(for name: String, locale: Locale = .current) -> String {
    switch self {
    case .empty: String(localized: "Type a value to save — a blank day stays blank.", table: "Log")
    case .notANumber: String(localized: "Use digits only, like \(DecimalInput.example(whole: 7, fraction: 5, locale: locale)).", table: "Log")
    case .negative: String(localized: "\(name) can’t be negative.", table: "Log")
    case .notWhole: String(localized: "\(name) is a whole number.", table: "Log")
    }
  }
}
