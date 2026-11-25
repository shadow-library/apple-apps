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
      week = try SampleWeek(clock: clock, now: now, currency: currency)
    } catch {
      throw .clock(error)
    }
    let identifier = zone.identifier
    do {
      try await stores.main.write { transaction in
        try week.write(zoneIdentifier: identifier, in: &transaction)
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
