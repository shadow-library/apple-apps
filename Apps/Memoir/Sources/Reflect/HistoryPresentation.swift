import Foundation
import MemoirCore
import ShadowStore

/// Where a history record opens: the screen that owns it, named as the reference names its section.
struct HistoryLink: Hashable {
  let route: MemoirRoute
  let section: String
}

struct HistoryField: Hashable {
  let label: String
  let value: String
}

/// One record as the stream row and the detail show it (`questRecord` … `grantRecord`, `reflect.derive.ts:197-357`).
struct HistoryPresentation: Equatable {
  let id: String
  let kind: HistoryKind
  let date: LocalDate
  let time: String?
  let text: String
  let value: String
  let title: String
  let fields: [HistoryField]
  let link: HistoryLink

  init(_ record: HistoryRecord, day: ReflectDay?, lookups: ReflectLookups?, home: CurrencyCode?) {
    id = record.id
    kind = record.kind
    date = record.date
    time = record.atMillis.flatMap { millis in day?.time(atMillis: millis) }
    switch record.item {
    case .questLog(let log, let name):
      let name = ReflectCopy.questName(name)
      let outcome = ReflectCopy.state(log.entry.state).lowercased()
      let reason = log.entry.reasonTag.map(ReflectCopy.reason)
      text = reason.map { String(localized: "\(name) · \(outcome) · \($0)", table: "Reflect") } ?? String(localized: "\(name) · \(outcome)", table: "Reflect")
      value = log.entry.xpAwarded > 0 ? String(localized: "+\(log.entry.xpAwarded) XP", table: "Reflect") : ReflectFormat.count(0)
      title = String(localized: "\(name) · \(outcome)", table: "Reflect")
      fields =
        [HistoryField(label: String(localized: "Outcome", table: "Reflect"), value: ReflectCopy.state(log.entry.state))]
        + (reason.map { [HistoryField(label: String(localized: "Reason", table: "Reflect"), value: $0)] } ?? []) + [
          HistoryField(label: String(localized: "Experience", table: "Reflect"), value: ReflectCopy.xp(log.entry.xpAwarded)),
          HistoryField(label: String(localized: "Coins", table: "Reflect"), value: ReflectFormat.count(log.entry.coinsAwarded)),
          HistoryField(label: String(localized: "Stat", table: "Reflect"), value: ReflectCopy.stat(log.entry.statAffinity)),
        ]
      link =
        record.kind == .recovery
        ? HistoryLink(route: .destination(.hero), section: String(localized: "Hero", table: "Reflect"))
        : HistoryLink(route: .quest(.detail(log.occurrence.quest)), section: String(localized: "Quests", table: "Reflect"))
    case .expense(let expense, let inHome, let category):
      let categoryName = lookups?.category(category) ?? ReflectCopy.builtInCategory(category) ?? category.key
      let amount = ReflectFormat.money(expense.amountMinor, expense.currency)
      let merchant = expense.merchant.flatMap { $0.isEmpty ? nil : $0 }
      text = merchant.map { String(localized: "\(categoryName) — \($0)", table: "Reflect") } ?? categoryName
      value = amount
      title = merchant ?? categoryName
      var fields = [HistoryField(label: String(localized: "Amount", table: "Reflect"), value: amount)]
      if let home, home != expense.currency {
        let converted =
          switch inHome {
          case .converted(let minor): ReflectFormat.money(minor, home)
          case .awaitingRate: String(localized: "Waiting for an exchange rate", table: "Reflect")
          case .unconvertible: String(localized: "Can’t be converted", table: "Reflect")
          }
        fields.append(HistoryField(label: String(localized: "In home currency", table: "Reflect"), value: converted))
      }
      fields.append(HistoryField(label: String(localized: "Category", table: "Reflect"), value: categoryName))
      if expense.receipt != nil {
        fields.append(HistoryField(label: String(localized: "Receipt", table: "Reflect"), value: String(localized: "Attached", table: "Reflect")))
      }
      self.fields = fields
      link = HistoryLink(route: .money(.expense(expense.id)), section: String(localized: "Money", table: "Reflect"))
    case .journal(let summary):
      text = summary.excerpt.isEmpty ? String(localized: "Journal entry", table: "Reflect") : summary.excerpt
      value = String(localized: "\(summary.wordCount) words", table: "Reflect")
      title = String(localized: "Journal entry", table: "Reflect")
      fields = [
        HistoryField(label: String(localized: "Words", table: "Reflect"), value: ReflectFormat.count(summary.wordCount)),
        HistoryField(
          label: String(localized: "Mood", table: "Reflect"),
          value: summary.entry.mood.map(ReflectFormat.count) ?? String(localized: "not recorded", table: "Reflect")),
        HistoryField(
          label: String(localized: "Tags", table: "Reflect"),
          value: summary.entry.tags.isEmpty ? String(localized: "none", table: "Reflect") : summary.entry.tags.formatted(.list(type: .and))),
      ]
      link = HistoryLink(route: .destination(.journal), section: String(localized: "Journal", table: "Reflect"))
    case .meal(let meal):
      let calories = String(localized: "\(meal.calories) kcal", table: "Reflect")
      text = meal.name
      value = calories
      title = meal.name
      fields = [
        HistoryField(label: String(localized: "Calories", table: "Reflect"), value: calories),
        HistoryField(label: String(localized: "Kind", table: "Reflect"), value: ReflectCopy.mealType(meal.mealType)),
      ]
      link = HistoryLink(route: .destination(.meals), section: String(localized: "Meals", table: "Reflect"))
    case .weight(let weight):
      let reading = ReflectCopy.kilograms(weight.kilograms)
      text = String(localized: "Weight \(reading)", table: "Reflect")
      value = reading
      title = text
      fields = [HistoryField(label: String(localized: "Value", table: "Reflect"), value: reading)]
      link = HistoryLink(route: .destination(.weight), section: String(localized: "Weight", table: "Reflect"))
    case .metric(let metric, let reading):
      let shown = ReflectCopy.metricValue(reading.value, of: metric)
      text = String(localized: "\(ReflectCopy.metricName(metric)) \(shown)", table: "Reflect")
      value = shown
      title = text
      let source =
        switch reading.source {
        case .imported: String(localized: "Health app", table: "Reflect")
        case .entry(.known(.questLog)): String(localized: "A quest", table: "Reflect")
        case .entry: String(localized: "Typed", table: "Reflect")
        }
      fields = [
        HistoryField(label: String(localized: "Value", table: "Reflect"), value: shown),
        HistoryField(label: String(localized: "Source", table: "Reflect"), value: source),
      ]
      link = HistoryLink(route: .destination(.bodyAndHealth), section: String(localized: "Body & health", table: "Reflect"))
    case .sideQuest(let sideQuest, let rewarded):
      let reward = Ruleset.current.quickLogs[.sideQuest]
      text = sideQuest.name
      value = rewarded ? String(localized: "+\(reward.xp) XP", table: "Reflect") : ReflectFormat.count(0)
      title = String(localized: "Side quest — \(sideQuest.name)", table: "Reflect")
      fields = [
        HistoryField(
          label: String(localized: "Reward", table: "Reflect"),
          value: rewarded
            ? String(localized: "\(reward.xp) XP · \(reward.coins) coins", table: "Reflect")
            : String(localized: "None — only the first \(reward.maxRewardedPerDay) a day are rewarded", table: "Reflect")),
        HistoryField(label: String(localized: "Streak", table: "Reflect"), value: String(localized: "Side quests never carry one", table: "Reflect")),
      ]
      link = HistoryLink(route: .destination(.sideQuests), section: String(localized: "Side quests", table: "Reflect"))
    case .unlock(let unlock):
      let kindName = ReflectCopy.unlockKind(unlock.kind)
      let name = ReflectCopy.unlockName(unlock)
      text = String(localized: "\(kindName) — \(name)", table: "Reflect")
      value = String(localized: "earned", table: "Reflect")
      title = name
      fields =
        [HistoryField(label: String(localized: "Kind", table: "Reflect"), value: kindName)]
        + (unlock.unlockedOn.map { [HistoryField(label: String(localized: "Earned", table: "Reflect"), value: ReflectFormat.shortDate($0))] } ?? []) + [
          HistoryField(
            label: String(localized: "Kept", table: "Reflect"), value: String(localized: "Never removed — a grant once earned is kept", table: "Reflect"))
        ]
      link = HistoryLink(route: .destination(.hero), section: String(localized: "Hero", table: "Reflect"))
    }
  }

  /// `deriveRecord`'s `when` (`reflect.derive.ts:472`).
  func when(today: LocalDate?) -> String {
    let day = date == today ? String(localized: "Today", table: "Reflect") : ReflectFormat.dayName(date)
    return time.map { String(localized: "\(day) \($0)", table: "Reflect") } ?? day
  }
}

/// A day's rows under its heading (`deriveHistory`, `reflect.derive.ts:427-433`).
struct HistoryGroup: Identifiable, Equatable {
  let date: LocalDate
  let label: String
  let rows: [HistoryPresentation]

  var id: LocalDate { date }

  static func grouping(_ rows: [HistoryPresentation], today: LocalDate?) -> [HistoryGroup] {
    var groups = [HistoryGroup]()
    for row in rows {
      if let last = groups.last, last.date == row.date {
        groups[groups.count - 1] = HistoryGroup(date: last.date, label: last.label, rows: last.rows + [row])
      } else {
        let name = ReflectFormat.dayName(row.date)
        let label = row.date == today ? String(localized: "Today · \(name)", table: "Reflect") : name
        groups.append(HistoryGroup(date: row.date, label: label, rows: [row]))
      }
    }
    return groups
  }
}

/// `historyTotals` (`reflect.derive.ts:386-402`), over the records the filter and search keep.
enum HistoryTotalsCopy {
  static func lines(_ totals: HistoryTotals) -> [String] {
    let spent = totals.spent.map { ReflectFormat.money($0.totalMinor, $0.home) }
    return [
      String(
        localized: "\(totals.questRecords) quest records · \(totals.outcomes) outcomes · \(totals.kept) kept", table: "Reflect"),
      spent.map { String(localized: "\(totals.expenses) expenses · \($0)", table: "Reflect") }
        ?? String(localized: "\(totals.expenses) expenses", table: "Reflect"),
      String(localized: "\(totals.journalEntries) journal entries · \(totals.words) words", table: "Reflect"),
      String(localized: "\(totals.metricEntries) metric entries · \(totals.meals) meals · \(totals.weights) weights", table: "Reflect"),
    ] + (totals.spent.flatMap { ReflectCopy.pending($0.pending) }.map { [$0] } ?? [])
  }

  static func count(matched: Int, isFiltered: Bool) -> String {
    isFiltered ? String(localized: "\(matched) matching records", table: "Reflect") : String(localized: "\(matched) records", table: "Reflect")
  }
}
