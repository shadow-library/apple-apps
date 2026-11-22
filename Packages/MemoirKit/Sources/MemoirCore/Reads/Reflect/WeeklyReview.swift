import Foundation
import ShadowStore

/// memoir-web's five review steps (`features/review/index.tsx:11-17`).
public enum ReviewStep: String, Sendable, CaseIterable {
  case kept
  case money
  case body
  case reflect
  case done
}

/// A quest's day in the review week (`reflect.derive.ts:752-757`): a moved occurrence counts nowhere, a partial is its own outcome.
public enum ReviewDayOutcome: String, Sendable, Hashable {
  case none
  case kept
  case partial
  case missed
}

public struct ReviewQuestRow: Sendable, Hashable {
  public let quest: UUID
  public let name: String?
  /// Monday to Sunday.
  public let days: [ReviewDayOutcome]

  /// Kept and partial days, each counted whole, as memoir-web's review row reads "held of occurrences" (`reflect.derive.ts:773-776`).
  public var held: Int { days.count { $0 == .kept || $0 == .partial } }
  public var occurrences: Int { days.count { $0 != .none } }
}

/// The review's first step (`reflect.derive.ts:880-895`). Unlike Insights, a partial counts as kept here, as the web counts it.
public struct ReviewKept: Sendable, Hashable {
  public let occurrences: Int
  public let held: Int
  public let partials: Int
  public let missesWithReason: Int
  /// `nil` with no occurrence.
  public let percent: Int?
  public let quests: [ReviewQuestRow]
  public let topReason: ReasonCount?
}

/// memoir-web `moneyFacts` (`reflect.derive.ts:781-838`).
public struct ReviewMoney: Sendable, Equatable {
  /// memoir-web `AVERAGE_WEEKS` (`reflect.derive.ts:779`).
  public static let averageWeeks = 8

  public let spent: HomeTotal
  public let expenseCount: Int
  /// The eight weeks before's converted spending over eight, halves up.
  public let weeklyAverageMinor: Int64
  public let spendDays: Int
  public var noSpendDays: Int { 7 - spendDays }
  public let biggestCategory: CategorySlice?
  /// Subscriptions whose latest confirmed cycle falls in the week.
  public let renewed: [UUID]
}

/// memoir-web `bodyFacts` (`reflect.derive.ts:840-889`): weight with two entries or more, a metric with three or more; the rest is too thin to read.
public struct ReviewBody: Sendable, Hashable {
  public static let minimumWeights = 2
  public static let minimumMetricDays = 3

  public let classes: Set<SyncClass>
  public let series: [BodySeries]
  /// In memoir-web's order, weight first; the first is the one the review names.
  public let thin: [BodySeries.Subject]
}

public struct IsoWeek: Sendable, Hashable {
  public let year: Int
  public let week: Int
}

public struct ReviewGlance: Sendable, Hashable {
  public let level: Int?
  public let weekXP: Int
  public let hp: DayHP?
  public let journalEntries: Int
  public let meals: Int
}

/// memoir-web `deriveReview` (`reflect.derive.ts:861-931`) as data, over last week (`reviewWeekStart`, `:857-859`): the Monday-to-Sunday week before the
/// one holding today.
public struct WeeklyReview: Sendable, Equatable {
  public let week: DateSpan
  public let isoWeek: IsoWeek
  public let kept: ReviewKept
  /// `nil` until the vault has its settings.
  public let money: ReviewMoney?
  public let body: ReviewBody
  public let glance: ReviewGlance
  public let answers: ReviewAnswers

  public static func weekUnderReview(today: LocalDate) -> DateSpan? {
    guard let start = today.startOfMondayWeek?.adding(days: -7) else { return nil }
    return DateSpan.mondayWeek(of: start)
  }

  /// ISO 8601: a week belongs to the year holding its Thursday and is numbered from that year's first Thursday (`isoWeekOf`, `reflect.derive.ts:743-750`).
  public static func isoWeek(of date: LocalDate) -> IsoWeek? {
    guard let monday = date.startOfMondayWeek, let thursday = monday.adding(days: 3), let january = LocalDate(year: thursday.year, month: 1, day: 1) else {
      return nil
    }
    return IsoWeek(year: thursday.year, week: thursday.days(since: january) / 7 + 1)
  }

  static func make(_ general: ReflectGeneral, body: ReflectBodySource, answers: ReviewAnswers, today: LocalDate) throws(FinanceError) -> WeeklyReview {
    guard let week = weekUnderReview(today: today), let isoWeek = isoWeek(of: week.start) else { throw .dateOutOfRange }
    let logs = general.logs(in: week)
    let counted = logs.filter { !Adherence.isCarried($0.entry.state) }
    let held = counted.count { Adherence.holds($0.entry.state) }
    let kept = ReviewKept(
      occurrences: counted.count, held: held, partials: counted.count { $0.entry.state == .partial },
      missesWithReason: counted.count { !Adherence.holds($0.entry.state) && $0.entry.reasonTag != nil },
      percent: counted.isEmpty ? nil : Fraction(numerator: held, denominator: counted.count)?.percent, quests: questRows(logs, week: week, names: general.questNames),
      topReason: ReasonCount.ranked(counted).first)
    let thin = body.series(in: week, minimum: (ReviewBody.minimumWeights, ReviewBody.minimumMetricDays))
    return WeeklyReview(
      week: week, isoWeek: isoWeek, kept: kept, money: try money(general.book, week: week), body: ReviewBody(classes: body.classes, series: thin.series, thin: thin.thin),
      glance: ReviewGlance(
        level: general.hero?.level, weekXP: general.xp(in: week), hp: general.today?.hp, journalEntries: general.journal.count { week.contains($0.date) },
        meals: general.meals.count { week.contains($0.date) }), answers: answers)
  }

  private static func questRows(_ logs: [QuestLogRow], week: DateSpan, names: [UUID: String]) -> [ReviewQuestRow] {
    var order = [UUID]()
    var byQuest = [UUID: [LocalDate: QuestLogRow]]()
    for log in logs {
      if byQuest[log.occurrence.quest] == nil { order.append(log.occurrence.quest) }
      byQuest[log.occurrence.quest, default: [:]][log.occurrence.date] = log
    }
    return order.map { quest in
      ReviewQuestRow(quest: quest, name: names[quest], days: week.dates.map { outcome(byQuest[quest]?[$0]?.entry.state) })
    }
  }

  private static func outcome(_ state: QuestLogState?) -> ReviewDayOutcome {
    guard let state, !Adherence.isCarried(state) else { return .none }
    if state == .partial { return .partial }
    return Adherence.holds(state) ? .kept : .missed
  }

  private static func money(_ book: MoneyBook, week: DateSpan) throws(FinanceError) -> ReviewMoney? {
    guard let converter = book.converter else { return nil }
    guard let priorStart = week.start.adding(days: -7 * ReviewMoney.averageWeeks), let priorEnd = week.start.adding(days: -1),
      let prior = DateSpan(start: priorStart, end: priorEnd)
    else { throw .dateOutOfRange }
    let expenses = book.expenses.filter { week.contains($0.occurredOn) }
    let priorTotal = try HomeTotal(home: converter.home, expenses: book.expenses.filter { prior.contains($0.occurredOn) }, converter: converter)
    var renewed = [SubscriptionRecord]()
    for subscription in book.subscriptions {
      do throws(FinanceError) {
        let schedule = try SubscriptionSchedule(subscription: subscription, confirmations: book.confirmations)
        if let last = schedule.lastConfirmed, week.contains(last) { renewed.append(subscription) }
      } catch {
        if error == .overflow { throw error }
      }
    }
    return ReviewMoney(
      spent: try HomeTotal(home: converter.home, expenses: expenses, converter: converter), expenseCount: expenses.count,
      weeklyAverageMinor: Int64(clamping: Exact.roundHalfUp(Int128(priorTotal.totalMinor), Int128(ReviewMoney.averageWeeks))),
      spendDays: Set(expenses.map(\.occurredOn)).count, biggestCategory: try book.breakdown(expenses, converter: converter).first { $0.count > 0 },
      renewed: renewed.map(\.id))
  }
}
