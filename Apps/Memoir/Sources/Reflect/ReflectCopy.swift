import Foundation
import MemoirCore
import ShadowStore

/// The reference's words for the Reflect surfaces (`lib/data/reflect.derive.ts`, `lib/data/labels.ts`, `lib/data/finance.types.ts`).
nonisolated enum ReflectCopy {
  static func kind(_ kind: HistoryKind) -> String {
    switch kind {
    case .quest: String(localized: "Quest", table: "Reflect")
    case .hero: String(localized: "Hero", table: "Reflect")
    case .expense: String(localized: "Expense", table: "Reflect")
    case .journal: String(localized: "Journal", table: "Reflect")
    case .meal: String(localized: "Meal", table: "Reflect")
    case .weight: String(localized: "Weight", table: "Reflect")
    case .health: String(localized: "Health", table: "Reflect")
    case .sideQuest: String(localized: "Side quest", table: "Reflect")
    case .recovery: String(localized: "Recovery", table: "Reflect")
    }
  }

  static var everything: String { String(localized: "Everything", table: "Reflect") }

  static func questName(_ name: String?) -> String {
    guard let name, !name.isEmpty else { return String(localized: "Unnamed quest", table: "Reflect") }
    return name
  }

  static func state(_ state: QuestLogState) -> String {
    switch state {
    case .completed: String(localized: "Kept", table: "Reflect")
    case .partial: String(localized: "Partial", table: "Reflect")
    case .skipped: String(localized: "Skipped", table: "Reflect")
    case .missed: String(localized: "Missed", table: "Reflect")
    case .late: String(localized: "Late", table: "Reflect")
    case .postponed: String(localized: "Postponed", table: "Reflect")
    case .rescheduled: String(localized: "Moved", table: "Reflect")
    case .recovery: String(localized: "Recovery", table: "Reflect")
    }
  }

  static func reason(_ tag: ReasonTag) -> String {
    switch tag {
    case .forgot: String(localized: "forgot", table: "Reflect")
    case .tooTired: String(localized: "too tired", table: "Reflect")
    case .taskTooBig: String(localized: "task too big", table: "Reflect")
    case .scheduleConflict: String(localized: "schedule conflict", table: "Reflect")
    case .avoidedIt: String(localized: "avoided it", table: "Reflect")
    case .emotionalResistance: String(localized: "emotional resistance", table: "Reflect")
    case .health: String(localized: "health", table: "Reflect")
    case .travel: String(localized: "travel", table: "Reflect")
    case .familySocial: String(localized: "family or social", table: "Reflect")
    case .workEmergency: String(localized: "work emergency", table: "Reflect")
    case .notImportantAnymore: String(localized: "not important anymore", table: "Reflect")
    case .poorlyPlanned: String(localized: "poorly planned", table: "Reflect")
    case .other: String(localized: "other", table: "Reflect")
    }
  }

  static func stat(_ stat: StatAffinity) -> String {
    switch stat {
    case .discipline: String(localized: "Discipline", table: "Reflect")
    case .body: String(localized: "Body", table: "Reflect")
    case .wealth: String(localized: "Wealth", table: "Reflect")
    case .mind: String(localized: "Mind", table: "Reflect")
    }
  }

  static func unlockKind(_ kind: UnlockKind) -> String {
    switch kind {
    case .achievement: String(localized: "Achievement", table: "Reflect")
    case .title: String(localized: "Title", table: "Reflect")
    case .cosmetic: String(localized: "Cosmetic", table: "Reflect")
    }
  }

  /// The catalogue's name, or the kind for an id this version of the app does not know.
  static func unlockName(_ unlock: UnlockRow) -> String {
    switch unlock.kind {
    case .achievement: AchievementID(rawValue: unlock.id).map(HeroCatalogue.name(of:)) ?? unlockKind(.achievement)
    case .title: TitleID(rawValue: unlock.id).map(HeroCatalogue.name(of:)) ?? unlockKind(.title)
    case .cosmetic: CosmeticID(rawValue: unlock.id).map(HeroCatalogue.name(of:)) ?? unlockKind(.cosmetic)
    }
  }

  /// The built-in categories by the names History shows, so its search finds them by those names.
  static let builtInCategoryNames = Dictionary(uniqueKeysWithValues: MoneyBook.builtInCategories.compactMap { key in builtInCategory(key).map { (key, $0) } })

  /// `BUILT_IN_CATEGORIES` (`finance.types.ts:64-74`): a built-in category is always named in the app's words.
  static func builtInCategory(_ key: CategoryKey) -> String? {
    switch key.key {
    case "food": String(localized: "Food", table: "Reflect")
    case "groceries": String(localized: "Groceries", table: "Reflect")
    case "transport": String(localized: "Transport", table: "Reflect")
    case "bills": String(localized: "Bills", table: "Reflect")
    case "health": String(localized: "Health", table: "Reflect")
    case "shopping": String(localized: "Shopping", table: "Reflect")
    case "home": String(localized: "Home", table: "Reflect")
    case "subs": String(localized: "Subscriptions", table: "Reflect")
    case "uncat": String(localized: "Uncategorised", table: "Reflect")
    default: nil
    }
  }

  static func mealType(_ type: StoredChoice<MealType>) -> String {
    switch type {
    case .known(.cooked): String(localized: "Cooked", table: "Reflect")
    case .known(.ateOut): String(localized: "Ate out", table: "Reflect")
    case .unknown(let raw): raw
    }
  }

  static func metricName(_ metric: MetricDescriptor) -> String {
    guard let builtin = metric.builtin else { return metric.name }
    return switch builtin {
    case .steps: String(localized: "Steps", table: "Reflect")
    case .activeEnergy: String(localized: "Calories burned", table: "Reflect")
    case .workoutMinutes: String(localized: "Workout minutes", table: "Reflect")
    case .weight: String(localized: "Weight", table: "Reflect")
    case .restingHeartRate: String(localized: "Resting heart rate", table: "Reflect")
    case .sleep: String(localized: "Sleep duration", table: "Reflect")
    case .waistCircumference: String(localized: "Waist circumference", table: "Reflect")
    case .water: String(localized: "Water", table: "Reflect")
    }
  }

  static func subjectName(_ subject: BodySeries.Subject) -> String {
    switch subject {
    case .weight: String(localized: "Weight", table: "Reflect")
    case .metric(let metric): metricName(metric)
    }
  }

  /// A metric's value in its own unit: durations in hours and minutes, water in litres as the reference shows it, counts whole.
  static func metricValue(_ value: DecimalText, of metric: MetricDescriptor) -> String {
    guard let number = ReflectFormat.double(value) else { return value.text }
    return metricValue(number, of: metric, exact: value)
  }

  static func metricValue(_ value: Fraction, of metric: MetricDescriptor) -> String {
    metricValue(Double(value.numerator) / Double(value.denominator), of: metric, exact: nil)
  }

  private static func metricValue(_ number: Double, of metric: MetricDescriptor, exact: DecimalText?) -> String {
    if metric.builtin == .water {
      return String(localized: "\((number / 1000).formatted(.number.precision(.fractionLength(0...2)))) L", table: "Reflect")
    }
    switch metric.valueType {
    case .known(.duration):
      return Duration.seconds(Int((number * 60).rounded())).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    case .known(.count):
      let count = number.formatted(.number.precision(.fractionLength(0)))
      return metric.builtin == .steps ? String(localized: "\(count) steps", table: "Reflect") : withUnit(count, metric.unit)
    case .known(.number):
      let text = exact.map(ReflectFormat.decimal) ?? number.formatted(.number.precision(.fractionLength(0...1)))
      return withUnit(text, metric.unit)
    case .known(.currency), .known(.boolean), .known(.text), .unknown:
      return exact?.text ?? number.formatted()
    }
  }

  private static func withUnit(_ value: String, _ unit: String?) -> String {
    guard let unit, !unit.isEmpty else { return value }
    return "\(value)\u{00A0}\(unit)"
  }

  static func kilograms(_ value: DecimalText) -> String {
    String(localized: "\(ReflectFormat.decimal(value)) kg", table: "Reflect")
  }

  /// `movement` (`reflect.derive.ts:181-183`): level, down or up by the change.
  static func movement(_ change: DecimalText?) -> String {
    guard let change, !ReflectFormat.isZero(change) else { return String(localized: "level", table: "Reflect") }
    let amount = ReflectFormat.decimal(ReflectFormat.magnitude(change))
    return ReflectFormat.isNegative(change) ? String(localized: "down \(amount)", table: "Reflect") : String(localized: "up \(amount)", table: "Reflect")
  }

  static func xp(_ value: Int) -> String {
    String(localized: "\(value) XP", table: "Reflect")
  }

  /// What a body section says about each class this device does not read.
  static func missingClasses(_ held: Set<SyncClass>) -> [String] {
    var notes = [String]()
    if !held.contains(.health) {
      notes.append(String(localized: "Weight and health metrics aren’t kept on this device, so none are shown here.", table: "Reflect"))
    }
    if !held.contains(.activity) {
      notes.append(String(localized: "Activity metrics aren’t kept on this device, so none are shown here.", table: "Reflect"))
    }
    return notes
  }

  static var bodyOnThisDevice: String {
    String(
      localized: "Weight and health entries come from this device’s own store. Anything another device keeps to itself shows only there.", table: "Reflect")
  }

  static func pending(_ pending: PendingConversions) -> String? {
    guard pending.count > 0 else { return nil }
    return String(localized: "\(pending.count) expenses aren’t converted to your home currency yet and are left out of this total.", table: "Reflect")
  }
}
