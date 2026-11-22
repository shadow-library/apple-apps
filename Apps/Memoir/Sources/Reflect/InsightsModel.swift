import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

struct InsightsReadKey: Hashable {
  let period: InsightPeriod
  let today: LocalDate
}

/// `features/insights/index.tsx`: the owner's history against itself over 30 days, 90 days (the reference's default) or a year.
@MainActor
@Observable
final class InsightsModel {
  private let context: MemoirScreenContext
  let bodyClasses: Set<SyncClass>
  let day: ReflectDayFollower
  let statistics = ReadObserver<InsightStatistics>()
  let lookups = ReadObserver<ReflectLookups>()
  var period = InsightPeriod.ninetyDays

  init(context: MemoirScreenContext, bodyClasses: Set<SyncClass> = ReflectBody.onThisDevice) {
    self.context = context
    self.bodyClasses = bodyClasses
    day = ReflectDayFollower(context: context)
  }

  var readKey: InsightsReadKey? {
    day.day.map { InsightsReadKey(period: period, today: $0.today) }
  }

  /// The statistics of the period chosen, never a stale period's while the new one loads.
  var shown: InsightStatistics? {
    statistics.state.value.flatMap { $0.period == period ? $0 : nil }
  }

  func followToday() async {
    await day.follow()
  }

  func observe() async {
    guard let key = readKey else { return }
    let stores = context.stores
    let bodyClasses = bodyClasses
    await statistics.run { ReflectReads.observeInsights(in: stores, period: key.period, bodyClasses: bodyClasses, today: key.today) }
  }

  func observeLookups() async {
    let main = context.stores.main
    await lookups.run { main.observe(ReflectLookups.self, ReflectLookupsQuery(streaks: true)) }
  }
}

/// A bar of a meter list or a column chart (`Bar`, `reflect.types.ts`): its label, the value it is drawn to, the caption beside it and what VoiceOver
/// reads.
struct InsightBar: Identifiable, Equatable {
  let id: String
  let label: String
  let value: Double
  let caption: String
  let accessibilityLabel: String
  let hasEntries: Bool
}

struct InsightKPI: Identifiable, Equatable {
  enum Kind: String {
    case kept
    case streak
    case xp
    case spend
  }

  let kind: Kind
  let label: String
  let value: String?
  /// The relative change against the period before, in percent; nil when there is nothing to compare.
  let deltaPercent: Double?
  let higherIsBetter: Bool
  let caption: String

  var id: Kind { kind }
}

/// `deriveInsights`' copy (`reflect.derive.ts:494-735`) over the core's statistics.
enum InsightsPresentation {
  static func periodNote(_ period: InsightPeriod) -> String {
    switch period {
    case .thirtyDays: String(localized: "The last 30 days, against the 30 before them.", table: "Reflect")
    case .ninetyDays: String(localized: "The last 90 days, against the 90 before them.", table: "Reflect")
    case .year: String(localized: "The last year, with nothing to compare it against but itself.", table: "Reflect")
    }
  }

  static func kpis(_ statistics: InsightStatistics, streak: LongestStreak?) -> [InsightKPI] {
    let whole = !statistics.period.isCompared
    let days = statistics.period.days
    return [
      InsightKPI(
        kind: .kept, label: String(localized: "Quests kept", table: "Reflect"), value: statistics.kept.percent.map(ReflectFormat.percent), deltaPercent: nil,
        higherIsBetter: true, caption: keptCaption(statistics, whole: whole, days: days)),
      InsightKPI(
        kind: .streak, label: String(localized: "Longest streak", table: "Reflect"),
        value: String(localized: "\(streak?.days ?? 0) days", table: "Reflect"), deltaPercent: nil, higherIsBetter: true,
        caption: streak.map { String(localized: "Held by \(ReflectCopy.questName($0.name)).", table: "Reflect") }
          ?? String(localized: "No streak recorded yet.", table: "Reflect")),
      InsightKPI(
        kind: .xp, label: String(localized: "XP earned", table: "Reflect"), value: ReflectFormat.count(statistics.xp),
        deltaPercent: whole ? nil : statistics.xpDelta.map(percent), higherIsBetter: true,
        caption: windowCaption(whole: whole, hasBaseline: (statistics.previousXP ?? 0) > 0, days: days)),
      InsightKPI(
        kind: .spend, label: String(localized: "Spent", table: "Reflect"), value: statistics.spent.map { ReflectFormat.money($0.totalMinor, $0.home) },
        deltaPercent: whole ? nil : statistics.spendDelta.map(percent), higherIsBetter: false,
        caption: statistics.spent == nil
          ? String(localized: "No home currency yet. Choose one in Settings.", table: "Reflect")
          : windowCaption(whole: whole, hasBaseline: (statistics.previousSpentMinor ?? 0) > 0, days: days)),
    ]
  }

  private static func keptCaption(_ statistics: InsightStatistics, whole: Bool, days: Int) -> String {
    keptCaption(current: statistics.kept.ratio, previous: statistics.previousKept?.ratio, whole: whole, days: days)
  }

  /// `keptCaption` (`reflect.derive.ts:494-500`): the point difference, since a relative change of a percentage misleads.
  static func keptCaption(current: Fraction?, previous: Fraction?, whole: Bool, days: Int) -> String {
    guard let current else { return String(localized: "No occurrences logged yet.", table: "Reflect") }
    if whole { return String(localized: "Over the last year.", table: "Reflect") }
    guard let previous else { return String(localized: "Nothing earlier to compare with yet.", table: "Reflect") }
    let points = keptPoints(current: current, previous: previous)
    if points == 0 { return String(localized: "About the same as the \(days) days before.", table: "Reflect") }
    return points > 0
      ? String(localized: "\(abs(points)) points higher than the \(days) days before.", table: "Reflect")
      : String(localized: "\(abs(points)) points lower than the \(days) days before.", table: "Reflect")
  }

  /// The difference in percentage points, exactly, with halves rounded up as the core rounds them and as the reference's `Math.round` does.
  static func keptPoints(current: Fraction, previous: Fraction) -> Int {
    let numerator = 100 * (current.numerator * previous.denominator - previous.numerator * current.denominator)
    return Fraction(numerator: numerator, denominator: current.denominator * previous.denominator)?.roundedHalfUp ?? 0
  }

  private static func windowCaption(whole: Bool, hasBaseline: Bool, days: Int) -> String {
    if whole { return String(localized: "Over the last year.", table: "Reflect") }
    return hasBaseline
      ? String(localized: "Compared with the \(days) days before.", table: "Reflect") : String(localized: "Nothing earlier to compare with yet.", table: "Reflect")
  }

  private static func percent(_ fraction: Fraction) -> Double {
    Double(fraction.numerator) / Double(fraction.denominator) * 100
  }

  static func byQuest(_ statistics: InsightStatistics) -> [InsightBar] {
    statistics.byQuest.map { row in
      let name = ReflectCopy.questName(row.name)
      let value = row.adherence.percent ?? 0
      return InsightBar(
        id: row.quest.uuidString, label: name, value: Double(value), caption: ReflectFormat.percent(value),
        accessibilityLabel: String(localized: "\(name): \(ReflectFormat.percent(value)) kept", table: "Reflect"), hasEntries: true)
    }
  }

  static func byWeekday(_ statistics: InsightStatistics) -> [InsightBar] {
    statistics.byWeekday.map { row in
      let percent = row.adherence.percent
      let caption = percent.map(ReflectFormat.percent) ?? String(localized: "no entries", table: "Reflect")
      let long = ReflectFormat.weekday(row.weekday, wide: true)
      return InsightBar(
        id: "\(row.weekday.rawValue)", label: ReflectFormat.weekday(row.weekday, wide: false), value: Double(percent ?? 0), caption: caption,
        accessibilityLabel: percent.map { String(localized: "\(long): \(ReflectFormat.percent($0)) kept", table: "Reflect") } ?? "\(long): \(caption)",
        hasEntries: percent != nil)
    }
  }

  static func weekdayNote(_ statistics: InsightStatistics) -> String {
    guard let weakest = statistics.weakestWeekday else {
      return String(localized: "Not enough occurrences yet to tell one weekday from another.", table: "Reflect")
    }
    return String(localized: "\(ReflectFormat.weekday(weakest, wide: true)) is your weakest weekday over this period.", table: "Reflect")
  }

  /// `xpByMonth` (`reflect.derive.ts:615-638`): a month's year shows where the year turns, and on the first month when the period spans two years.
  static func byMonth(_ statistics: InsightStatistics) -> [InsightBar] {
    let months = statistics.xpByMonth
    let spansYears = months.first?.year != months.last?.year
    return months.enumerated().map { index, month in
      let crossesYear = index > 0 && months[index - 1].year != month.year
      let caption = month.xp == 0 ? String(localized: "no entries", table: "Reflect") : ReflectCopy.xp(month.xp)
      return InsightBar(
        id: "\(month.year)-\(month.month)", label: ReflectFormat.month(year: month.year, month: month.month, withYear: crossesYear || (index == 0 && spansYears)),
        value: Double(month.xp), caption: month.xp == 0 ? caption : String(localized: "\(ReflectFormat.compact(month.xp)) XP", table: "Reflect"),
        accessibilityLabel: "\(ReflectFormat.longMonth(year: month.year, month: month.month)): \(caption)", hasEntries: month.xp != 0)
    }
  }

  static func monthNote(_ statistics: InsightStatistics) -> String {
    statistics.xpByMonth.contains { $0.xp > 0 }
      ? String(localized: "Each bar is the experience earned that month, not a running total — it moves with how much you logged.", table: "Reflect")
      : String(localized: "Nothing logged in this period yet. It fills in on its own.", table: "Reflect")
  }

  static func reasons(_ statistics: InsightStatistics) -> [InsightBar] {
    statistics.reasons.map { reason in
      let label = ReflectCopy.reason(reason.reason)
      return InsightBar(
        id: reason.reason.rawValue, label: label, value: Double(reason.count), caption: ReflectFormat.count(reason.count),
        accessibilityLabel: String(localized: "\(label): \(reason.count) times", table: "Reflect"), hasEntries: true)
    }
  }

  static func reasonsNote(_ statistics: InsightStatistics) -> String {
    guard let top = statistics.reasons.first else { return String(localized: "No reasons were given in this period.", table: "Reflect") }
    return String(localized: "\(ReflectCopy.reason(top.reason)) is the reason you give most, \(top.count) times.", table: "Reflect")
  }

  static func spending(_ statistics: InsightStatistics, lookups: ReflectLookups?) -> [InsightBar] {
    guard let home = statistics.spent?.home else { return [] }
    return statistics.spendByCategory.map { slice in
      let label = lookups?.category(slice.category) ?? ReflectCopy.builtInCategory(slice.category) ?? slice.category.key
      let caption = ReflectFormat.money(slice.totalMinor, home)
      return InsightBar(
        id: slice.category.key, label: label, value: Double(slice.totalMinor), caption: caption, accessibilityLabel: "\(label): \(caption)", hasEntries: true)
    }
  }

  static func spendingNote(_ statistics: InsightStatistics, lookups: ReflectLookups?) -> String {
    guard let top = spending(statistics, lookups: lookups).first else {
      return String(localized: "No expenses were logged in this period.", table: "Reflect")
    }
    return String(localized: "\(top.label) is your largest category at \(top.caption).", table: "Reflect")
  }

  /// `trendSeries` (`reflect.derive.ts:666-699`): weight with its latest value and move, a metric with its average.
  static func trendValue(_ series: BodySeries) -> String {
    switch series.subject {
    case .weight:
      let last = series.points.last?.value.map(ReflectCopy.kilograms) ?? ""
      return String(localized: "\(last) · \(ReflectCopy.movement(series.change))", table: "Reflect")
    case .metric(let metric):
      let mean = series.mean.map { ReflectCopy.metricValue($0, of: metric) } ?? "—"
      return String(localized: "\(mean) average", table: "Reflect")
    }
  }
}
