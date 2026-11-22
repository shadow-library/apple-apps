import Foundation
import ShadowCore
import ShadowStore
import ShadowText

/// memoir-web `HistoryKind` (`lib/data/reflect.types.ts`, `reflect.derive.ts:29-41`).
public enum HistoryKind: String, Sendable, CaseIterable {
  case quest
  case hero
  case expense
  case journal
  case meal
  case weight
  case health
  case sideQuest = "side-quest"
  case recovery
}

public enum HistoryItem: Sendable, Equatable {
  case questLog(QuestLogRow, questName: String?)
  case expense(ExpenseRecord, inHome: HomeAmount, category: CategoryKey)
  case journal(JournalEntrySummary)
  case meal(MealRecord)
  case weight(WeightRecord)
  case metric(MetricDescriptor, MetricDayReading)
  case sideQuest(SideQuestRecord, rewarded: Bool)
  case unlock(UnlockRow)
}

public struct HistoryRecord: Sendable, Equatable {
  /// Stable across reads: the kind's prefix and the record's own key, as memoir-web names its rows.
  public let id: String
  public let kind: HistoryKind
  public let date: LocalDate
  /// When it was logged or performed, if known; orders records within a day.
  public let atMillis: Int64?
  /// The class of the store it came from.
  public let syncClass: SyncClass
  public let item: HistoryItem
  /// Only text safe to match a typed query against: names, merchants and category labels. Journal text, notes and reason notes are never matched, as
  /// memoir-web's `haystack` leaves them out (`reflect.derive.ts:213-214`); an unlock, whose name is the app's copy, matches nothing.
  let haystack: String
}

public struct HistoryQuery: Sendable, Hashable {
  /// memoir-web `HISTORY_PAGE_SIZE` (`reflect.derive.ts:43`).
  public static let pageSize = 20

  /// `nil` lists every kind.
  public var kinds: Set<HistoryKind>?
  public var search: String
  public var page: PageRequest

  public init(kinds: Set<HistoryKind>? = nil, search: String = "", page: PageRequest) {
    self.kinds = kinds
    self.search = search
    self.page = page
  }

  public static func page(_ number: Int, kinds: Set<HistoryKind>? = nil, search: String = "") throws(MemoirReadError) -> HistoryQuery {
    HistoryQuery(kinds: kinds, search: search, page: try PageRequest(offset: max(0, number - 1) * pageSize, limit: pageSize))
  }
}

/// memoir-web `historyTotals` (`reflect.derive.ts:386-402`) over the matched records. `spent` leaves out expenses still waiting for a rate.
public struct HistoryTotals: Sendable, Equatable {
  public let questRecords: Int
  public let outcomes: Int
  public let kept: Int
  public let expenses: Int
  public let spent: HomeTotal?
  public let journalEntries: Int
  public let words: Int
  public let metricEntries: Int
  public let meals: Int
  public let weights: Int
}

/// memoir-web `deriveHistory` (`reflect.derive.ts:404-437`): every record newest first, filtered by kind and a typed query, paged.
public struct HistoryPage: Sendable, Equatable {
  /// The classes whose stores the stream read.
  public let classes: Set<SyncClass>
  public let records: ReadPage<HistoryRecord>
  public let totals: HistoryTotals
  public let totalRecords: Int

  static func make(_ general: ReflectGeneral, body: ReflectBodySource, query: HistoryQuery) throws(FinanceError) -> HistoryPage {
    let all = records(general, body: body)
    let needle = query.search.jsTrim().jsToLowerCase()
    let matched = all.filter { record in
      (query.kinds?.contains(record.kind) ?? true) && (needle.isEmpty || record.haystack.jsToLowerCase().jsIncludes(needle))
    }
    return HistoryPage(
      classes: body.classes.union([.general]), records: ReadPage(matched, page: query.page), totals: try totals(matched, book: general.book), totalRecords: all.count)
  }

  static func records(_ general: ReflectGeneral, body: ReflectBodySource) -> [HistoryRecord] {
    var records = [HistoryRecord]()
    for log in general.logs {
      let name = general.questNames[log.occurrence.quest]
      let kind: HistoryKind = log.entry.state == .recovery ? .recovery : .quest
      records.append(
        HistoryRecord(
          id: "log:\(log.entry.id.lowercasedString)", kind: kind, date: log.occurrence.date, atMillis: log.entry.performedAtMillis, syncClass: .general,
          item: .questLog(log, questName: name), haystack: name ?? ""))
    }
    let converter = general.book.converter
    let labels = Dictionary(general.book.categoryRecords.map { ($0.categoryKey, $0.label) }) { first, _ in first }
    for expense in general.book.expenses {
      let category = general.book.category(of: expense)
      records.append(
        HistoryRecord(
          id: "expense:\(expense.id.lowercasedString)", kind: .expense, date: expense.occurredOn, atMillis: expense.loggedAtMillis, syncClass: .general,
          item: .expense(expense, inHome: converter?.homeAmount(of: expense) ?? .awaitingRate, category: category),
          haystack: "\(labels[category] ?? category.key) \(expense.merchant ?? "")"))
    }
    for entry in general.journal {
      records.append(
        HistoryRecord(
          id: "journal:\(entry.id.lowercasedString)", kind: .journal, date: entry.date, atMillis: entry.loggedAtMillis, syncClass: .general,
          item: .journal(JournalEntrySummary(entry)), haystack: ""))
    }
    for meal in general.meals {
      records.append(
        HistoryRecord(
          id: "meal:\(meal.id.lowercasedString)", kind: .meal, date: meal.date, atMillis: meal.loggedAtMillis, syncClass: .general, item: .meal(meal),
          haystack: meal.name))
    }
    for sideQuest in general.sideQuests {
      records.append(
        HistoryRecord(
          id: "side-quest:\(sideQuest.id.lowercasedString)", kind: .sideQuest, date: sideQuest.date, atMillis: sideQuest.loggedAtMillis, syncClass: .general,
          item: .sideQuest(sideQuest, rewarded: general.rewards.grants[sideQuest.id] != nil), haystack: sideQuest.name))
    }
    for unlock in general.unlocks {
      guard let date = unlock.unlockedOn else { continue }
      records.append(
        HistoryRecord(
          id: "grant:\(unlock.kind.rawValue):\(unlock.id)", kind: .hero, date: date, atMillis: nil, syncClass: .general, item: .unlock(unlock), haystack: ""))
    }
    for weight in body.weights {
      records.append(
        HistoryRecord(
          id: "weight:\(weight.date.isoString)", kind: .weight, date: weight.date, atMillis: weight.loggedAtMillis, syncClass: .health, item: .weight(weight),
          haystack: ""))
    }
    for snapshot in body.metrics {
      for descriptor in snapshot.descriptors {
        for reading in (snapshot.days[descriptor.reference] ?? [:]).values {
          records.append(
            HistoryRecord(
              id: "metric:\(descriptor.reference.id.lowercasedString):\(reading.date.isoString)", kind: .health, date: reading.date, atMillis: nil,
              syncClass: snapshot.syncClass, item: .metric(descriptor, reading), haystack: descriptor.name))
        }
      }
    }
    return records.sorted { first, second in
      if first.date != second.date { return first.date > second.date }
      if first.atMillis != second.atMillis { return (first.atMillis ?? .min) > (second.atMillis ?? .min) }
      return first.id > second.id
    }
  }

  private static func totals(_ matched: [HistoryRecord], book: MoneyBook) throws(FinanceError) -> HistoryTotals {
    var logs = [QuestLogRow]()
    var expenses = [ExpenseRecord]()
    var journal = [JournalEntrySummary]()
    var metrics = 0
    var meals = 0
    var weights = 0
    for record in matched {
      switch record.item {
      case .questLog(let log, _): logs.append(log)
      case .expense(let expense, _, _): expenses.append(expense)
      case .journal(let summary): journal.append(summary)
      case .metric: metrics += 1
      case .meal: meals += 1
      case .weight: weights += 1
      case .sideQuest, .unlock: continue
      }
    }
    let counted = logs.filter { !Adherence.isCarried($0.entry.state) }
    return HistoryTotals(
      questRecords: logs.count, outcomes: counted.count, kept: counted.count { Adherence.holds($0.entry.state) }, expenses: expenses.count,
      spent: try book.converter.map { converter throws(FinanceError) in try HomeTotal(home: converter.home, expenses: expenses, converter: converter) },
      journalEntries: journal.count, words: Exact.sum(journal.map(\.wordCount)), metricEntries: metrics, meals: meals, weights: weights)
  }
}
