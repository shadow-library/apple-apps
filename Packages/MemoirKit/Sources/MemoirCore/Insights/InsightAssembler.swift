import Foundation
import ShadowCore
import ShadowStore
import ShadowText

/// The read-scope classes named on a result; coarser than kinds on purpose: what kind of data was read and how much, never which rows
/// (ai-worker.types.ts:7-8).
public enum InsightReadClass: String, CaseIterable, Sendable {
  case quests
  case questLogs = "quest_logs"
  case heroEvents = "hero_events"
  case dailyStates = "daily_states"
  case progressionEvents = "progression_events"
  case finance
  case metrics
  case meals
  case sideQuests = "side_quests"
  case journalReflectionReason = "journal_reflection_reason"
  case health

  var contextKey: String {
    switch self {
    case .quests: "quests"
    case .questLogs: "questLogs"
    case .heroEvents: "heroEvents"
    case .dailyStates: "dailyStates"
    case .progressionEvents: "progressionEvents"
    case .finance: "finance"
    case .metrics: "metrics"
    case .meals: "meals"
    case .sideQuests: "sideQuests"
    case .journalReflectionReason: "journal"
    case .health: "health"
    }
  }
}

/// What one assembly put in front of the model. `sensitiveSources` are kept only for the quote check and never stored.
public struct InsightAssembly: Sendable, Equatable {
  public let context: OrderedJSON
  public let consent: InsightConsentSnapshot
  public let windowStart: LocalDate?
  public let dataClasses: [InsightReadClass]
  public let rowCounts: [InsightReadClass: Int]
  public let sensitiveSources: [String]
  public let questIDs: [String]
  /// The highest sync class of anything in the context: a result paraphrasing health-class data is stored with health-class data.
  public let resultClass: SyncClass
}

/// Builds the context from the owner's own data. Consent decides what is read, before a row is fetched: without the journal class no journal entry is
/// read and no reflection or reason text is asked of replay or kept, and without the health class the activity and restricted stores are not opened.
// apps/memoir-server/src/modules/ai-worker/read-assembly.service.ts:49-106; ai-read.repository.ts
public struct InsightAssembler: Sendable {
  /// Trailing windows, in days, tried in turn when everything does not fit the budget.
  static let windows = [365, 180, 90, 30, 14, 7]
  public static let defaultBudget = 200_000

  let stores: MemoirStores
  let replay: any InsightReplaySource
  /// The longest user prompt, in UTF-16 units, the assembly may produce.
  let budget: Int

  public init(stores: MemoirStores, replay: any InsightReplaySource, budget: Int = InsightAssembler.defaultBudget) {
    self.stores = stores
    self.replay = replay
    self.budget = budget
  }

  /// The whole history when it fits, otherwise the widest trailing window ending on `today` that does.
  public func assemble(question: String, consent: InsightConsentSnapshot, today: LocalDate) async throws(InsightError) -> InsightAssembly {
    let rows = try await read(consent: consent)
    var units = 0
    for window in [nil] + Self.windows.map(Optional.some) {
      let start = window.flatMap { today.adding(days: -$0) }
      let assembly = rows.assembly(from: start, consent: consent)
      units = InsightPrompt.user(question: question, context: assembly.context).utf16.count
      if units <= budget { return assembly }
    }
    throw .contextTooLarge(units: units, budget: budget)
  }

  private func read(consent: InsightConsentSnapshot) async throws(InsightError) -> InsightRows {
    let state = try await replay.insightState(includingText: consent.journal)
    do throws(StoreError) {
      var rows = try await stores.main.read { transaction in
        var rows = InsightRows(profile: state.profile)
        try rows.readMain(transaction, replay: state, journal: consent.journal)
        return rows
      }
      guard consent.health else { return rows }
      rows.absorb(
        try await stores.activity.read { transaction in
          var rows = InsightRows(profile: state.profile)
          try rows.readMetrics(ActivityMetric.self, transaction, into: .health)
          return rows
        })
      rows.absorb(
        try await stores.restricted.read { transaction in
          var rows = InsightRows(profile: state.profile)
          try rows.readMetrics(HealthMetric.self, transaction, into: .health)
          try rows.readWeights(transaction)
          return rows
        })
      return rows
    } catch {
      throw .converting(error)
    }
  }
}

struct InsightRow: Sendable {
  let date: LocalDate?
  let object: OrderedJSONObject
  var texts: [String] = []
  var syncClass: SyncClass = .general
}

struct InsightRows: Sendable {
  let profile: InsightProfile
  var sections: [InsightReadClass: [InsightRow]] = [:]
  var questIDs: [String] = []

  init(profile: InsightProfile) {
    self.profile = profile
  }

  mutating func absorb(_ other: InsightRows) {
    for (readClass, rows) in other.sections { sections[readClass, default: []] += rows }
  }

  func assembly(from start: LocalDate?, consent: InsightConsentSnapshot) -> InsightAssembly {
    let windowed = sections.mapValues { rows in rows.filter { row in start.map { start in row.date.map { $0 >= start } ?? true } ?? true } }
    var context: [(key: String, value: OrderedJSON)] = [
      (
        key: "profile",
        value: .object(
          JSONRow()
            .put("timezone", profile.timeZone).put("intensityMode", profile.intensityMode.rawValue).put("windowStart", start?.isoString).object)
      )
    ]
    for readClass in InsightReadClass.allCases { context.append((key: readClass.contextKey, value: .array((windowed[readClass] ?? []).map { .object($0.object) }))) }
    let present = InsightReadClass.allCases.filter { !(windowed[$0] ?? []).isEmpty }
    let health = windowed[.health] ?? []
    let resultClass: SyncClass =
      health.contains { $0.syncClass == .health } ? .health : health.contains { $0.syncClass == .activity } ? .activity : .general
    return InsightAssembly(
      context: .object(OrderedJSONObject(context)), consent: consent, windowStart: start, dataClasses: present,
      rowCounts: Dictionary(uniqueKeysWithValues: present.map { ($0, windowed[$0]?.count ?? 0) }),
      sensitiveSources: [InsightReadClass.journalReflectionReason, .questLogs, .progressionEvents].flatMap { (windowed[$0] ?? []).flatMap(\.texts) },
      questIDs: questIDs, resultClass: resultClass)
  }

  mutating func append(_ readClass: InsightReadClass, _ row: InsightRow) {
    sections[readClass, default: []].append(row)
  }

  mutating func readMain(_ transaction: ReadTransaction, replay: InsightReplayState, journal: Bool) throws(StoreError) {
    let schedules = Dictionary(replay.quests.map { ($0.quest, $0) }) { first, _ in first }
    for quest in try QuestRecord.listing(in: transaction).entries.map(\.record) {
      questIDs.append(quest.id.lowercasedString)
      append(.quests, InsightRow(date: nil, object: Self.quest(quest, schedules[quest.id])))
    }
    for log in replay.questLogs { append(.questLogs, Self.questLog(log, includingText: journal)) }
    for event in replay.heroEvents { append(.heroEvents, InsightRow(date: event.date, object: Self.heroEvent(event))) }
    for day in replay.dailyStates { append(.dailyStates, InsightRow(date: day.date, object: Self.dailyState(day))) }
    for event in replay.progressionEvents { append(.progressionEvents, Self.progression(event, includingText: journal)) }
    try readFinance(transaction)
    for meal in try live(MealRecord.self, transaction) {
      append(
        .meals,
        InsightRow(
          date: meal.date,
          object: JSONRow().put("date", meal.date.isoString).put("name", meal.name).put("calories", meal.calories).put("mealType", meal.mealType.rawValue).object))
    }
    for sideQuest in try live(SideQuestRecord.self, transaction) {
      append(.sideQuests, InsightRow(date: sideQuest.date, object: JSONRow().put("date", sideQuest.date.isoString).put("name", sideQuest.name).object))
    }
    try readMetrics(GeneralMetric.self, transaction, into: .metrics)
    guard journal else { return }
    for entry in try live(JournalEntryRecord.self, transaction) {
      let object = JSONRow().put("date", entry.date.isoString).put("text", entry.text).put("mood", entry.mood).put(
        "tags", OrderedJSON.array(entry.tags.map(OrderedJSON.string))
      ).object
      append(.journalReflectionReason, InsightRow(date: entry.date, object: object, texts: entry.text.isEmpty ? [] : [entry.text]))
    }
  }

  /// `receipt` and the owner's notes are never read (ai-read.repository.ts:150-179).
  private mutating func readFinance(_ transaction: ReadTransaction) throws(StoreError) {
    let home = try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record.defaultCurrency
    let rates = home == nil ? [] : try FxRateRecord.listing(in: transaction).entries.map(\.record)
    let converter = home.map { HomeConverter(home: $0, rates: rates) }
    for expense in try live(ExpenseRecord.self, transaction) {
      let object = JSONRow().put("entity", "expense").put("amountMinor", expense.amountMinor).put("currency", expense.currency.code).put(
        "homeAmountMinor", converter?.homeAmount(of: expense).minor
      ).put("categoryId", expense.category.key).put("merchant", expense.merchant).put("occurredOn", expense.occurredOn.isoString).object
      append(.finance, InsightRow(date: expense.occurredOn, object: object))
    }
    for subscription in try live(SubscriptionRecord.self, transaction) {
      let object = JSONRow().put("entity", "subscription").put("name", subscription.name).put("amountMinor", subscription.amountMinor).put(
        "currency", subscription.currency.code
      ).put("frequency", subscription.frequency.rawValue).put("categoryId", subscription.category.key).put("active", subscription.active).object
      append(.finance, InsightRow(date: nil, object: object))
    }
  }

  /// A metric's definition and its days, both of the metric's class; a day's value is the owner's entry, else the Health import.
  mutating func readMetrics<Class: MetricClass>(_: Class.Type, _ transaction: ReadTransaction, into readClass: InsightReadClass) throws(StoreError) {
    let metrics = try live(MetricRecord<Class>.self, transaction)
    guard !metrics.isEmpty else { return }
    let known = Set(metrics.map(\.id))
    for metric in metrics {
      let object = JSONRow().put("entity", "metric").put("id", metric.id.description).put("name", metric.name).put("unit", metric.unit).put(
        "valueType", metric.valueType.rawValue
      ).put("direction", metric.direction.rawValue).object
      append(readClass, InsightRow(date: nil, object: object, syncClass: Class.syncClass))
    }
    for day in try live(MetricDayRecord<Class>.self, transaction) where known.contains(day.metric) {
      guard let value = day.value else { continue }
      let object = JSONRow().put("entity", "metric_entry").put("metricId", day.metric.description).put("date", day.date.isoString).put("value", value.text).put(
        "source", day.entry?.source.rawValue ?? "health"
      ).object
      append(readClass, InsightRow(date: day.date, object: object, syncClass: Class.syncClass))
    }
  }

  /// Body mass rides the health consent (ai-read.repository.ts:208-214).
  mutating func readWeights(_ transaction: ReadTransaction) throws(StoreError) {
    for weight in try live(WeightRecord.self, transaction) {
      append(.health, InsightRow(date: weight.date, object: JSONRow().put("date", weight.date.isoString).put("kg", weight.kilograms.text).object, syncClass: .health))
    }
  }

  private func live<Record: MemoirRecord>(_: Record.Type, _ transaction: ReadTransaction) throws(StoreError) -> [Record] {
    try Record.listing(in: transaction).entries.filter { !$0.isRemoved }.map(\.record)
  }

  private static func quest(_ quest: QuestRecord, _ state: InsightQuestState?) -> OrderedJSONObject {
    JSONRow().put("id", quest.id.lowercasedString).put("name", quest.name).put("startTimeMin", state?.startTimeMinutes).put("durationMin", state?.durationMinutes).put(
      "statAffinity", state?.statAffinity?.rawValue
    ).put("strictness", state?.strictness.rawValue).put("recurrence", state?.recurrence.map(recurrence) ?? .null).put("reminderEnabled", quest.reminderEnabled).put(
      "reminderLeadMin", quest.reminderLeadMinutes
    ).put("active", state?.active ?? true).object
  }

  private static func questLog(_ log: InsightQuestLog, includingText: Bool) -> InsightRow {
    var row = JSONRow().put("questId", log.quest.lowercasedString).put("date", log.date.isoString).put("state", log.state.rawValue).put("xpAwarded", log.xpAwarded).put(
      "coinsAwarded", log.coinsAwarded
    ).put("strictness", log.strictness.rawValue).put("intensityModeAtLog", log.intensityModeAtLog.rawValue).put("reasonTag", log.reasonTag).put(
      "rescheduledToMin", log.rescheduledToMinutes
    ).put("postponedToDate", log.postponedToDate?.isoString).put("performedAt", log.performedAtMillis.map(instant) ?? .null)
    guard includingText else { return InsightRow(date: log.date, object: row.object) }
    row = row.put("reasonNote", log.reasonNote).put("reflectionText", log.reflectionText)
    return InsightRow(date: log.date, object: row.object, texts: [log.reasonNote, log.reflectionText].compactMap { $0 }.filter { !$0.isEmpty })
  }

  private static func heroEvent(_ event: InsightHeroEvent) -> OrderedJSONObject {
    JSONRow().put("type", event.type).put("questId", event.quest?.lowercasedString).put("state", event.state?.rawValue).put("xpDelta", event.xpDelta).put(
      "coinsDelta", event.coinsDelta
    ).put("statAffinity", event.statAffinity?.rawValue).put("statDelta", event.statDelta).put("levelAfter", event.levelAfter).put("achievementId", event.achievement).put(
      "date", event.date.isoString
    ).object
  }

  private static func dailyState(_ day: InsightDailyState) -> OrderedJSONObject {
    JSONRow().put("date", day.date.isoString).put("intensityMode", day.intensityMode.rawValue).put("hpStart", day.hpStart).put("hpEnd", day.hpEnd).put("hpMax", day.hpMax).put(
      "crownXpGranted", day.crownXPGranted
    ).put("crownBankedXp", day.crownBankedXP).put("momentumBucket", day.momentumBucket).put("missedCount", day.missedCount).object
  }

  private static func progression(_ event: InsightProgressionEvent, includingText: Bool) -> InsightRow {
    let row: JSONRow
    switch event {
    case .recoveryQuest(let date, let source, let state, let isReturnerDay, let completed, let reflection):
      var recovery = JSONRow().put("entity", "recovery_quest").put("date", date.isoString).put("sourceQuestId", source.lowercasedString).put("state", state.rawValue).put(
        "isReturnerDay", isReturnerDay
      ).put("completedAt", completed.map(instant) ?? .null)
      if includingText { recovery = recovery.put("reflectionText", reflection) }
      row = recovery
    case .comeback(let date, let kind, let xpBonus, let coinBonus):
      row = JSONRow().put("entity", "comeback").put("date", date.isoString).put("kind", kind).put("xpBonus", xpBonus).put("coinBonus", coinBonus)
    case .returner(let date, let daysAbsent, let shieldPending):
      row = JSONRow().put("entity", "returner").put("date", date.isoString).put("daysAbsent", daysAbsent).put("shieldPending", shieldPending)
    case .shieldConsumption(let date, let quest):
      row = JSONRow().put("entity", "shield_consumption").put("date", date.isoString).put("questId", quest.lowercasedString)
    case .achievement(let id, let earned):
      row = JSONRow().put("entity", "achievement").put("achievementId", id).put("earnedAt", instant(earned))
    case .title(let id, let earned):
      row = JSONRow().put("entity", "title").put("titleId", id).put("earnedAt", instant(earned))
    }
    let texts = includingText ? [event.reflectionText].compactMap { $0 }.filter { !$0.isEmpty } : []
    return InsightRow(date: event.date, object: row.object, texts: texts)
  }

  private static func recurrence(_ rule: RecurrenceRule) -> OrderedJSON {
    var row = JSONRow()
    switch rule.frequency {
    case .daily: row = row.put("frequency", "daily")
    case .weekly(let days): row = row.put("frequency", "weekly").put("weekdays", OrderedJSON.array(days.sorted { $0.rawValue < $1.rawValue }.map { .int(Int64($0.rawValue)) }))
    case .monthly(.dayOfMonth(let day)): row = row.put("frequency", "monthly").put("dayOfMonth", day)
    case .monthly(.nthWeekday(let weekday, let ordinal)): row = row.put("frequency", "monthly").put("weekday", weekday.rawValue).put("ordinal", "\(ordinal)")
    case .yearly: row = row.put("frequency", "yearly")
    }
    row = row.put("interval", rule.interval).put("startDate", rule.startDate.isoString)
    switch rule.end {
    case .never: row = row.put("end", OrderedJSON.null)
    case .count(let count): row = row.put("count", count)
    case .until(let date): row = row.put("until", date.isoString)
    }
    return .object(row.put("exceptions", OrderedJSON.array(rule.exceptions.sorted().map { .string($0.isoString) })).object)
  }

  /// `Date.prototype.toISOString` of an instant within years 0 to 9999.
  static func instant(_ millis: Int64) -> OrderedJSON {
    let day = millis >= 0 ? millis / 86_400_000 : (millis - 86_399_999) / 86_400_000
    let rest = millis - day * 86_400_000
    guard let date = LocalDate(daysSinceEpoch: Int(day)) else { return .null }
    let pad = { (value: Int64, width: Int) in String(repeating: "0", count: max(0, width - String(value).count)) + String(value) }
    let time = "\(pad(rest / 3_600_000, 2)):\(pad(rest / 60_000 % 60, 2)):\(pad(rest / 1000 % 60, 2)).\(pad(rest % 1000, 3))"
    return .string("\(date.isoString)T\(time)Z")
  }
}

/// A row in the reference's column order; an absent optional is `null`, as a selected column without a value is.
struct JSONRow {
  private var pairs: [(key: String, value: OrderedJSON)] = []

  var object: OrderedJSONObject { OrderedJSONObject(pairs) }

  func put(_ key: String, _ value: OrderedJSON) -> JSONRow {
    var row = self
    row.pairs.append((key: key, value: value))
    return row
  }

  func put(_ key: String, _ value: String?) -> JSONRow {
    put(key, value.map(OrderedJSON.string) ?? .null)
  }

  func put(_ key: String, _ value: Int?) -> JSONRow {
    put(key, value.map { OrderedJSON.int(Int64($0)) } ?? .null)
  }

  func put(_ key: String, _ value: Int64?) -> JSONRow {
    put(key, value.map(OrderedJSON.int) ?? .null)
  }

  func put(_ key: String, _ value: Bool) -> JSONRow {
    put(key, OrderedJSON.bool(value))
  }
}
