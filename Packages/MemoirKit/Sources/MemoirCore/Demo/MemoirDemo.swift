import Foundation
import ShadowAI
import ShadowCore
import ShadowStore

public enum MemoirDemoError: ShadowError {
  case store(StoreError)
  case clock(CalendarError)

  public var code: String {
    switch self {
    case .store(let error): error.code
    case .clock(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let error): error.errorDescription
    case .clock(let error): error.errorDescription
    }
  }
}

/// The sample life the demo opens on: a week of five quests kept and missed, a few expenses, two journal entries and two meals, all stamped in the past
/// week as if they had been logged as they happened, and the scripted answers of the demo's insights. Every name and word is the demo's own.
public enum MemoirDemo {
  public static let walk = quest(1)
  static let lines = quest(2)
  static let reading = quest(3)
  static let stretch = quest(4)
  static let budget = quest(5)

  /// How many whole days of history come before today.
  static let days = 7

  public static let fallback = "This is the demo, so this answer comes from a script on this device rather than from a model."

  /// The insight call's replies, given in turn; each suggestion names a quest the seed creates, so the guardrails keep it.
  public static var insightRules: [DemoRule] {
    [DemoRule(DemoMatch(schema: InsightPrompt.schemaName), replies: insightReplies.map(DemoReply.json))]
  }

  static var insightReplies: [JSONValue] {
    [
      [
        "answer": .string(
          "Over the past week your morning quests held best: the three lines were written on six of seven days and the walk happened on five. Evening reading slipped on the days that also had a late expense or a long work day logged."
        ),
        "patterns": ["Morning quests are kept far more often than evening ones.", "Reading slips on the days a journal entry mentions work running late."],
        "suggestions": [
          [
            "kind": "shift_time", "questId": .string(reading.uuidString.lowercased()),
            "text": "Try reading at nine instead of half past, before the evening fills up.",
          ]
        ],
        "limitationNote": "This is the demo: the answer is scripted, and a week of sample data supports only rough patterns.",
      ],
      [
        "answer": .string(
          "Spending was steady through the week, with food and groceries the largest share. The days you walked in the morning were also the days with the fewest small purchases."
        ),
        "patterns": ["Food and groceries make up most of the week's spending."],
        "suggestions": [
          ["kind": "adjust_duration", "questId": .string(walk.uuidString.lowercased()), "text": "A shorter walk on busy mornings may keep it going."]
        ],
        "limitationNote": "This is the demo: the answer is scripted, and a week of sample data supports only rough patterns.",
      ],
    ]
  }

  public static func isSeeded(_ stores: MemoirStores) async throws(MemoirDemoError) -> Bool {
    do {
      return try await stores.main.read { transaction in
        guard case .absent = try AccountSettingsRecord.read(key: .accountSettings, in: transaction) else { return true }
        return !(try MemoirCommand.listing(in: transaction).entries.isEmpty)
      }
    } catch {
      throw .store(error)
    }
  }

  /// Writes the sample week into an empty vault in one write, the account's zone set to `zone` from its first day; an account already set up is left
  /// alone. Today's quests are left open.
  public static func seed(_ stores: MemoirStores, now: Date, zone: TimeZone, currency: CurrencyCode) async throws(MemoirDemoError) {
    guard try await !isSeeded(stores) else { return }
    let clock = IssueClock(timeZone: zone)
    let week: SampleWeek
    do throws(CalendarError) {
      week = try SampleWeek(clock: clock, now: now)
    } catch {
      throw .clock(error)
    }
    let identifier = zone.identifier
    do {
      try await stores.main.write { transaction in
        try week.write(currency: currency, zoneIdentifier: identifier, in: &transaction)
      }
    } catch {
      throw .store(error)
    }
  }

  private static func quest(_ number: Int) -> UUID {
    guard let id = UUID(uuidString: String(format: "6d656d6f-6972-4000-8000-%012d", number)) else { preconditionFailure("a valid quest id") }
    return id
  }
}

/// The past week as instants of the account's zone: day 0 is the first day of the account, the last is yesterday.
private struct SampleWeek: Sendable {
  let clock: IssueClock
  let first: LocalDate

  init(clock: IssueClock, now: Date) throws(CalendarError) {
    guard let millis = Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) else { throw .dateOutOfRange }
    let today = try clock.localDate(at: millis)
    guard let first = today.adding(days: -MemoirDemo.days) else { throw .dateOutOfRange }
    self.clock = clock
    self.first = first
  }

  func date(_ day: Int) throws -> LocalDate {
    guard let date = first.adding(days: day) else { throw CalendarError.dateOutOfRange }
    return date
  }

  func millis(_ day: Int, minute: Int) throws -> Int64 {
    try clock.resolve(minuteOfDay: minute, on: try date(day)).instantMillis
  }

  func issuer(_ day: Int, minute: Int) throws -> CommandIssuer {
    let date = Date(timeIntervalSince1970: Double(try millis(day, minute: minute)) / 1000)
    return CommandIssuer(clock: clock, wallClock: { date })
  }

  func write(currency: CurrencyCode, zoneIdentifier: String, in transaction: inout WriteTransaction) throws {
    try AccountSettingsRecord(defaultCurrency: currency, enabledCurrencies: [currency], monthlyBudget: MoneyAmount(amountMinor: 150_000, currency: currency))
      .create(in: &transaction)
    let opening = try issuer(0, minute: 420)
    try opening.issue(.accountSetTimeZone(try TimeZoneChange(identifier: zoneIdentifier)), in: &transaction)
    for quest in try quests() {
      try opening.issue(.questCreate(QuestCreation(questId: quest.record.id, schedule: quest.schedule)), content: quest.record, in: &transaction)
      try quest.record.create(in: &transaction)
    }
    for log in logs { try issuer(log.day, minute: log.minute).issue(log.body(try date(log.day)), in: &transaction) }
    for expense in try expenses(currency: currency) {
      try ExpenseEdits.create(expense.record, issuer: try issuer(expense.day, minute: expense.minute), in: &transaction)
    }
    for entry in journal {
      let record = JournalEntryRecord(id: UUID.v7(), date: try date(entry.day), text: entry.text, mood: entry.mood, loggedAtMillis: try millis(entry.day, minute: 1260))
      try issuer(entry.day, minute: 1260).issue(.journalSave(QuickLogEntry(id: record.id, date: record.date)), content: record, in: &transaction)
      try record.create(in: &transaction)
    }
    for meal in meals {
      let record = MealRecord(
        id: UUID.v7(), date: try date(meal.day), name: meal.name, calories: meal.calories, mealType: .known(meal.type), loggedAtMillis: try millis(meal.day, minute: 780))
      try issuer(meal.day, minute: 780).issue(.mealLog(QuickLogEntry(id: record.id, date: record.date)), content: record, in: &transaction)
      try record.create(in: &transaction)
    }
  }

  private func quests() throws -> [(record: QuestRecord, schedule: QuestSchedule)] {
    let daily = try RecurrenceRule(frequency: .daily, startDate: first)
    let weekly = try RecurrenceRule(frequency: .weekly([try date(3).weekday]), startDate: first)
    return [
      (QuestRecord(id: MemoirDemo.lines, name: "Write three lines"), try schedule(.anchor, at: 420, minutes: 10, stat: .mind, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.walk, name: "Morning walk"), try schedule(.routine, at: 450, minutes: 30, stat: .body, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.reading, name: "Read before bed"), try schedule(.routine, at: 1290, minutes: 20, stat: .mind, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.stretch, name: "Stretch"), try schedule(.optional, at: nil, minutes: 10, stat: .body, recurrence: daily)),
      (QuestRecord(id: MemoirDemo.budget, name: "Check the budget"), try schedule(.goal, at: nil, minutes: 20, stat: .wealth, recurrence: weekly)),
    ]
  }

  private func schedule(_ strictness: Strictness, at start: Int?, minutes: Int, stat: StatAffinity, recurrence: RecurrenceRule) throws -> QuestSchedule {
    try QuestSchedule(strictness: strictness, startTimeMinutes: start, durationMinutes: minutes, statAffinity: stat, recurrence: recurrence)
  }

  private struct Log {
    let day: Int
    let minute: Int
    let body: (LocalDate) -> MemoirCommandBody
  }

  private var logs: [Log] {
    func completed(_ quest: UUID, on days: [Int], at minute: Int) -> [Log] {
      days.map { day in Log(day: day, minute: minute) { .questComplete(Occurrence(quest: quest, date: $0)) } }
    }
    let skipped = Log(day: 2, minute: 480) { .questSkip(QuestBreak(occurrence: Occurrence(quest: MemoirDemo.walk, date: $0), reasonTag: .tooTired)) }
    let partial = Log(day: 5, minute: 500) { .questPartial(Occurrence(quest: MemoirDemo.walk, date: $0)) }
    let entries =
      completed(MemoirDemo.lines, on: [0, 1, 2, 4, 5, 6], at: 425) + completed(MemoirDemo.walk, on: [0, 1, 3, 4, 6], at: 470)
      + completed(MemoirDemo.reading, on: [0, 2, 3, 5, 6], at: 1305) + completed(MemoirDemo.stretch, on: [1, 4], at: 1080)
      + completed(MemoirDemo.budget, on: [3], at: 600) + [skipped, partial]
    return entries.sorted { ($0.day, $0.minute) < ($1.day, $1.minute) }
  }

  private func expenses(currency: CurrencyCode) throws -> [(day: Int, minute: Int, record: ExpenseRecord)] {
    let samples: [(day: Int, minute: Int, minor: Int64, category: String, merchant: String?, note: String?)] = [
      (1, 1110, 4_235, "groceries", "Market Hall", nil), (2, 750, 1_250, "food", "Corner Café", nil), (3, 520, 2_800, "transport", nil, "Train tickets"),
      (4, 1140, 1_599, "shopping", "Bookshop on the Square", nil), (5, 1230, 1_890, "food", "Noodle Bar", nil), (6, 1100, 3_160, "groceries", "Market Hall", nil),
    ]
    return try samples.compactMap { sample in
      guard let category = CategoryKey(sample.category) else { return nil }
      let record = ExpenseRecord(
        id: UUID.v7(), amountMinor: sample.minor, currency: currency, occurredOn: try date(sample.day), category: category, merchant: sample.merchant,
        note: sample.note, loggedAtMillis: try millis(sample.day, minute: sample.minute))
      return (sample.day, sample.minute, record)
    }
  }

  private var journal: [(day: Int, text: String, mood: Int)] {
    [
      (4, "Slow start, but the walk along the river cleared my head and I finally finished the chapter I had been putting off.", 4),
      (6, "Work ran long again. Kept the evening quiet, made soup and read for a while before bed.", 3),
    ]
  }

  private var meals: [(day: Int, name: String, calories: Int, type: MealType)] {
    [(5, "Noodle bar lunch", 650, .ateOut), (6, "Lentil soup", 420, .cooked)]
  }
}
