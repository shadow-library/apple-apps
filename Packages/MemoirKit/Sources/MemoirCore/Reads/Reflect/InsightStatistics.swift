import Foundation
import ShadowStore

/// memoir-web `InsightPeriod` (`lib/data/reflect.derive.ts:142`).
public enum InsightPeriod: Int, Sendable, CaseIterable {
  case thirtyDays = 30
  case ninetyDays = 90
  case year = 365

  public var days: Int { rawValue }
  /// The year is read on its own; the shorter periods are compared with the same number of days before them.
  public var isCompared: Bool { self != .year }
}

public struct QuestAdherence: Sendable, Hashable {
  public let quest: UUID
  public let name: String?
  public let adherence: Adherence
}

public struct WeekdayAdherence: Sendable, Hashable {
  public let weekday: LocalDate.Weekday
  public let adherence: Adherence
}

public struct MonthXP: Sendable, Hashable {
  public let year: Int
  public let month: Int
  public let xp: Int
}

/// A body series over a window: a weight's or a metric's days, oldest first, with its exact mean and its first-to-last move.
public struct BodySeries: Sendable, Hashable {
  public enum Subject: Sendable, Hashable {
    case weight
    case metric(MetricDescriptor)
  }

  public let subject: Subject
  public let syncClass: SyncClass
  public let points: [DayValue<DecimalText>]
  public let mean: Fraction?
  /// The last value less the first, exactly.
  public let change: DecimalText?

  init(subject: Subject, syncClass: SyncClass, points: [(LocalDate, DecimalText)]) {
    self.subject = subject
    self.syncClass = syncClass
    self.points = points.map { DayValue(date: $0.0, value: $0.1) }
    mean = DecimalText.mean(points.map(\.1))
    change = points.count >= 2 ? points.last.flatMap { last in points.first.flatMap { last.1.minus($0.1) } } : nil
  }
}

extension ReflectBodySource {
  /// Weight and every metric with at least `minimum` days in the span, weight first, then metrics in each class's order.
  func series(in span: DateSpan, minimum: (weight: Int, metric: Int)) -> (series: [BodySeries], thin: [BodySeries.Subject]) {
    var series = [BodySeries]()
    var thin = [BodySeries.Subject]()
    if classes.contains(.health) {
      let weights = weights.filter { span.contains($0.date) }.sorted { $0.date < $1.date }
      if weights.count >= minimum.weight {
        series.append(BodySeries(subject: .weight, syncClass: .health, points: weights.map { ($0.date, $0.kilograms) }))
      } else {
        thin.append(.weight)
      }
    }
    for snapshot in metrics {
      for descriptor in snapshot.descriptors {
        let readings = snapshot.values(of: descriptor.reference, in: span)
        guard readings.count >= minimum.metric else {
          thin.append(.metric(descriptor))
          continue
        }
        series.append(BodySeries(subject: .metric(descriptor), syncClass: snapshot.syncClass, points: readings.map { ($0.date, $0.value) }))
      }
    }
    return (series, thin)
  }
}

/// memoir-web `deriveInsights` (`reflect.derive.ts:701-735`) as data: adherence with a partial counted as half, XP, spending, reasons and body trends
/// over the period ending today, and for 30 and 90 days the same measures over the period before.
public struct InsightStatistics: Sendable, Equatable {
  public let period: InsightPeriod
  public let window: DateSpan
  public let previousWindow: DateSpan?
  public let kept: Adherence
  public let previousKept: Adherence?
  public let xp: Int
  public let previousXP: Int?
  /// The relative change against the period before; `nil` for the year or when the period before earned none.
  public let xpDelta: Fraction?
  /// `nil` until the vault has its settings.
  public let spent: HomeTotal?
  public let previousSpentMinor: Int64?
  public let spendDelta: Fraction?
  /// Most kept first; equal ones in the order their quest was first logged.
  public let byQuest: [QuestAdherence]
  /// Monday to Sunday.
  public let byWeekday: [WeekdayAdherence]
  /// memoir-web `weakestWeekday` (`reflect.derive.ts:587-591`): the lowest-kept weekday with entries, once at least two weekdays have them.
  public let weakestWeekday: LocalDate.Weekday?
  /// Each calendar month the period touches, the first counted from the period's start.
  public let xpByMonth: [MonthXP]
  public let reasons: [ReasonCount]
  /// The six largest categories by home total.
  public let spendByCategory: [CategorySlice]
  /// The classes the body trends were read from; empty when none was asked for.
  public let bodyClasses: Set<SyncClass>
  /// Weight and metrics with at least two days in the period.
  public let body: [BodySeries]

  static func make(_ general: ReflectGeneral, body: ReflectBodySource, period: InsightPeriod, today: LocalDate) throws(FinanceError) -> InsightStatistics {
    guard let window = DateSpan.trailing(period.days, endingOn: today), let previousEnd = window.start.adding(days: -1) else { throw .dateOutOfRange }
    let previous = period.isCompared ? DateSpan.trailing(period.days, endingOn: previousEnd) : nil
    let logs = general.logs(in: window)
    let xp = general.xp(in: window)
    let previousXP = previous.map(general.xp(in:))
    let converter = general.book.converter
    let inWindow = general.book.expenses.filter { window.contains($0.occurredOn) }
    let spent = try converter.map { converter throws(FinanceError) in try HomeTotal(home: converter.home, expenses: inWindow, converter: converter) }
    let previousSpent = try converter.flatMap { converter throws(FinanceError) -> Int64? in
      guard let previous else { return nil }
      return try HomeTotal(home: converter.home, expenses: general.book.expenses.filter { previous.contains($0.occurredOn) }, converter: converter).totalMinor
    }
    let counted = logs.filter { !Adherence.isCarried($0.entry.state) }
    let byWeekday = LocalDate.Weekday.allCases.map { day in WeekdayAdherence(weekday: day, adherence: Adherence(counted.filter { $0.occurrence.date.weekday == day })) }
    let rated = byWeekday.filter { $0.adherence.occurrences > 0 }
    let weakest = rated.count < 2 ? nil : rated.min { ($0.adherence.percent ?? 0) < ($1.adherence.percent ?? 0) }?.weekday
    return InsightStatistics(
      period: period, window: window, previousWindow: previous, kept: Adherence(logs), previousKept: previous.map { Adherence(general.logs(in: $0)) }, xp: xp,
      previousXP: previousXP, xpDelta: previousXP.flatMap { SpendDelta.fraction(current: Int64(xp), previous: Int64($0)) }, spent: spent,
      previousSpentMinor: previousSpent, spendDelta: previousSpent.flatMap { previous in spent.flatMap { SpendDelta.fraction(current: $0.totalMinor, previous: previous) } },
      byQuest: byQuest(counted, names: general.questNames), byWeekday: byWeekday, weakestWeekday: weakest,
      xpByMonth: xpByMonth(general, window: window), reasons: ReasonCount.ranked(logs),
      spendByCategory: try converter.map { converter throws(FinanceError) in
        Array(try general.book.breakdown(inWindow, converter: converter).filter { $0.count > 0 }.prefix(6))
      } ?? [], bodyClasses: body.classes, body: body.series(in: window, minimum: (2, 2)).series)
  }

  /// memoir-web `adherenceByQuest` (`reflect.derive.ts:557-571`): each quest's kept share, most kept first.
  private static func byQuest(_ counted: [QuestLogRow], names: [UUID: String]) -> [QuestAdherence] {
    var order = [UUID]()
    var grouped = [UUID: [QuestLogRow]]()
    for log in counted {
      if grouped[log.occurrence.quest] == nil { order.append(log.occurrence.quest) }
      grouped[log.occurrence.quest, default: []].append(log)
    }
    let rows = order.map { QuestAdherence(quest: $0, name: names[$0], adherence: Adherence(grouped[$0] ?? [])) }
    return rows.enumerated().sorted { first, second in
      let left = first.element.adherence.percent ?? 0
      let right = second.element.adherence.percent ?? 0
      return left != right ? left > right : first.offset < second.offset
    }.map(\.element)
  }

  /// memoir-web `xpByMonth` (`reflect.derive.ts:615-638`), stepping months as integers.
  private static func xpByMonth(_ general: ReflectGeneral, window: DateSpan) -> [MonthXP] {
    var months = [MonthXP]()
    var index = window.start.monthIndex
    while index <= window.end.monthIndex {
      let year = LocalDate.floorDivide(index, 12)
      let month = index - year * 12 + 1
      guard let first = LocalDate(year: year, month: month, day: 1), let span = DateSpan.month(of: first),
        let clipped = DateSpan(start: max(span.start, window.start), end: min(span.end, window.end))
      else { break }
      months.append(MonthXP(year: year, month: month, xp: general.xp(in: clipped)))
      index += 1
    }
    return months
  }
}
