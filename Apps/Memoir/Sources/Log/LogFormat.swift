import Foundation
import MemoirCore

/// The Log screens' words (`lib/data/quick-logs.types.ts`, `quick-logs.rules.ts`, `entry-caps.ts`) with dates, numbers and units in the owner's locale. A
/// `LocalDate` has no zone, so it is placed at UTC midnight and formatted there.
nonisolated enum LogFormat {
  static let utc = TimeZone(identifier: "UTC") ?? .gmt
  private static let posix = Locale(identifier: "en_US_POSIX")

  static func midnight(of date: LocalDate) -> Date {
    Date(timeIntervalSince1970: TimeInterval(date.daysSinceEpoch) * 86_400)
  }

  /// "Monday, 2 March" (`formatLocalDate`).
  static func dayName(_ date: LocalDate) -> String {
    midnight(of: date).formatted(Date.FormatStyle(timeZone: utc).weekday(.wide).day().month(.wide))
  }

  static func shortDate(_ date: LocalDate) -> String {
    midnight(of: date).formatted(Date.FormatStyle(timeZone: utc).day().month(.abbreviated))
  }

  static func day(_ date: LocalDate, today: LocalDate) -> String {
    date == today ? String(localized: "Today", table: "Log") : shortDate(date)
  }

  static func time(millis: Int64, in zone: TimeZone) -> String {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
  }

  static func decimal(_ text: DecimalText) -> Decimal? {
    Decimal(string: text.text, locale: posix)
  }

  static func number(_ text: DecimalText, fractionDigits: ClosedRange<Int> = 0...2) -> String {
    guard let value = decimal(text) else { return text.text }
    return value.formatted(.number.precision(.fractionLength(fractionDigits)))
  }

  static func calories(_ kcal: Int) -> String {
    String(localized: "\(kcal.formatted(.number)) kcal", table: "Log")
  }

  static func words(_ count: Int) -> String {
    String(localized: "\(count) words", table: "Log")
  }

  static func weight(_ kilograms: DecimalText, in unit: WeightUnit) -> String {
    let shown = WeightConversion.convert(kilograms, from: .kilograms, to: unit) ?? kilograms
    return weightText(shown, in: unit)
  }

  static func weight(_ kilograms: Fraction, in unit: WeightUnit) -> String? {
    guard let rounded = kilograms.rounded(toPlaces: WeightConversion.defaultPlaces + 1) else { return nil }
    return weight(rounded, in: unit)
  }

  /// A change keeps its sign, "+1.2 kg" or "−0.4 kg", as the web's `signDisplay: 'exceptZero'`.
  static func weightChange(_ kilograms: DecimalText, in unit: WeightUnit) -> String {
    let shown = WeightConversion.convert(kilograms, from: .kilograms, to: unit) ?? kilograms
    let value = decimal(shown) ?? 0
    let number = value.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
    return unit == .kilograms ? String(localized: "\(number) kg", table: "Log") : String(localized: "\(number) lb", table: "Log")
  }

  static func unitSymbol(_ unit: WeightUnit) -> String {
    unit == .kilograms ? String(localized: "kg", table: "Log") : String(localized: "lb", table: "Log")
  }

  private static func weightText(_ value: DecimalText, in unit: WeightUnit) -> String {
    let number = (decimal(value) ?? 0).formatted(.number.precision(.fractionLength(1)))
    return unit == .kilograms ? String(localized: "\(number) kg", table: "Log") : String(localized: "\(number) lb", table: "Log")
  }

  static func moodLabel(_ mood: Int) -> String {
    switch mood {
    case 1: String(localized: "Low", table: "Log")
    case 2: String(localized: "Flat", table: "Log")
    case 3: String(localized: "Steady", table: "Log")
    case 4: String(localized: "Good", table: "Log")
    case 5: String(localized: "Bright", table: "Log")
    default: String(localized: "No mood", table: "Log")
    }
  }

  static func moodGlyph(_ mood: Int) -> String {
    switch mood {
    case 1: "○"
    case 2: "◍"
    case 3: "◉"
    case 4: "◈"
    default: "✦"
    }
  }

  /// `moodNote` (`synced-quick-log-provider.ts:71-76`): the rounded mean of the days with a mood, halves up.
  static func moodNote(_ moods: [DayValue<Int>]) -> String {
    let logged = moods.compactMap(\.value)
    guard !logged.isEmpty else { return String(localized: "No mood logged in the last 28 days.", table: "Log") }
    let mean = (2 * logged.reduce(0, +) + logged.count) / (2 * logged.count)
    return String(localized: "Mostly \(moodLabel(mean)) across \(logged.count) days with a mood.", table: "Log")
  }

  static func mealType(_ type: StoredChoice<MealType>) -> String {
    switch type {
    case .known(.cooked): String(localized: "Cooked", table: "Log")
    case .known(.ateOut): String(localized: "Ate out", table: "Log")
    case .unknown: String(localized: "Meal", table: "Log")
    }
  }

  static func stat(_ stat: StatAffinity) -> String {
    switch stat {
    case .discipline: String(localized: "Discipline", table: "Log")
    case .body: String(localized: "Body", table: "Log")
    case .wealth: String(localized: "Wealth", table: "Log")
    case .mind: String(localized: "Mind", table: "Log")
    }
  }

  /// `deriveCapAdvisory`'s message (`entry-caps.ts:35-40`) without the subscription that lifts the count, which native Memoir does not sell.
  static func capNote(_ advisory: EntryCapAdvisory?) -> String? {
    guard let advisory else { return nil }
    let noun = capNoun(advisory.module)
    switch advisory.level {
    case .clear:
      return nil
    case .approaching:
      return String(localized: "\(advisory.used) of \(advisory.limit) \(noun) logged this month. Nothing changes at the limit — entries keep saving.", table: "Log")
    case .reached:
      return advisory.used == advisory.limit
        ? String(localized: "You have logged \(advisory.used) \(noun) this month and reached the monthly allowance of \(advisory.limit). Everything still saves.", table: "Log")
        : String(localized: "You have logged \(advisory.used) \(noun) this month, past the monthly allowance of \(advisory.limit). Everything still saves.", table: "Log")
    }
  }

  private static func capNoun(_ module: LoggableModule) -> String {
    switch module {
    case .expenses: String(localized: "expenses", table: "Log")
    case .journal: String(localized: "journal entries", table: "Log")
    case .meals: String(localized: "meals", table: "Log")
    case .weight: String(localized: "weight entries", table: "Log")
    case .sideQuests: String(localized: "side quests", table: "Log")
    }
  }
}
