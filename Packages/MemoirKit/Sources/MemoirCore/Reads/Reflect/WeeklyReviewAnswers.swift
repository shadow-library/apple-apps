import Foundation
import GRDB
import ShadowStore

/// memoir-web `REVIEW_PROMPTS` (`lib/data/reflect.derive.ts:101-105`); the app words them.
public enum ReviewPrompt: String, Sendable, CaseIterable {
  case better
  case change
  case carry
}

public struct ReviewAnswers: Sendable, Hashable {
  public static let none = ReviewAnswers(answers: [:], completedAtMillis: nil)

  public let answers: [ReviewPrompt: String]
  public let completedAtMillis: Int64?

  public init(answers: [ReviewPrompt: String], completedAtMillis: Int64?) {
    self.answers = answers
    self.completedAtMillis = completedAtMillis
  }

  public var isComplete: Bool { completedAtMillis != nil }
}

/// The weekly review's answers and its completion: this device's own, never synced, as memoir-web keeps them in store metadata
/// (`lib/sync/synced-reflect-provider.ts:116-121,278-288`). `mm_local_review_answer` and `mm_local_review_completion` are created by the first write,
/// read only after a `tableExists` check, and hold one week, the week under review: a write for a week clears every other week's rows, as the web
/// replaces a review left over from an earlier week. `clear(in:)` removes them when the vault is deleted.
public enum WeeklyReviewAnswers {
  static let answerTable = "mm_local_review_answer"
  static let completionTable = "mm_local_review_completion"
  private static let definitions = [
    """
    CREATE TABLE IF NOT EXISTS mm_local_review_answer (
      week_start TEXT NOT NULL, prompt TEXT NOT NULL, answer TEXT NOT NULL, PRIMARY KEY (week_start, prompt)
    ) STRICT, WITHOUT ROWID
    """,
    "CREATE TABLE IF NOT EXISTS mm_local_review_completion (week_start TEXT PRIMARY KEY, completed_at_millis INTEGER NOT NULL) STRICT, WITHOUT ROWID",
  ]

  /// Saves the answer for the week starting `week`; an empty answer removes it.
  public static func save(_ answer: String, for prompt: ReviewPrompt, week: LocalDate, in stores: MemoirStores) async throws(MemoirReadError) {
    try await write(week: week, in: stores) { database in
      if answer.isEmpty {
        try database.execute(sql: "DELETE FROM \(answerTable) WHERE week_start = ? AND prompt = ?", arguments: [week.isoString, prompt.rawValue])
      } else {
        try database.execute(
          sql: "INSERT OR REPLACE INTO \(answerTable) (week_start, prompt, answer) VALUES (?, ?, ?)", arguments: [week.isoString, prompt.rawValue, answer])
      }
    }
  }

  /// Closes the week; closing it again keeps the first time.
  public static func complete(week: LocalDate, atMillis: Int64, in stores: MemoirStores) async throws(MemoirReadError) {
    try await write(week: week, in: stores) { database in
      try database.execute(
        sql: "INSERT OR IGNORE INTO \(completionTable) (week_start, completed_at_millis) VALUES (?, ?)", arguments: [week.isoString, atMillis])
    }
  }

  public static func answers(week: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> ReviewAnswers {
    try MemoirProjectionSQL.run {
      let database = transaction.database
      var answers = [ReviewPrompt: String]()
      if try database.tableExists(answerTable) {
        for row in try Row.fetchAll(database, sql: "SELECT prompt, answer FROM \(answerTable) WHERE week_start = ?", arguments: [week.isoString]) {
          guard let prompt = ReviewPrompt(rawValue: row["prompt"]) else { continue }
          answers[prompt] = row["answer"]
        }
      }
      let completed =
        try database.tableExists(completionTable)
        ? try Int64.fetchOne(database, sql: "SELECT completed_at_millis FROM \(completionTable) WHERE week_start = ?", arguments: [week.isoString]) : nil
      return ReviewAnswers(answers: answers, completedAtMillis: completed)
    }
  }

  /// Every week this device holds answers or a completion for, normally the one under review, whichever week that was; for the export.
  public static func weeks(in transaction: ReadTransaction) throws(StoreError) -> [LocalDate: ReviewAnswers] {
    let starts = try MemoirProjectionSQL.run {
      let database = transaction.database
      var starts = Set<String>()
      for table in [answerTable, completionTable] where try database.tableExists(table) {
        starts.formUnion(try String.fetchAll(database, sql: "SELECT DISTINCT week_start FROM \(table)"))
      }
      return starts
    }
    var weeks = [LocalDate: ReviewAnswers]()
    for start in starts {
      guard let week = LocalDate(isoString: start) else { continue }
      weeks[week] = try answers(week: week, in: transaction)
    }
    return weeks
  }

  /// Puts back the weeks an export held, in the restore's main-store transaction, replacing whatever this device held; an empty answer is left out.
  public static func restore(_ weeks: [LocalDate: ReviewAnswers], in database: Database) throws {
    for definition in definitions { try database.execute(sql: definition) }
    try database.execute(sql: "DELETE FROM \(answerTable)")
    try database.execute(sql: "DELETE FROM \(completionTable)")
    for (week, review) in weeks {
      for (prompt, answer) in review.answers where !answer.isEmpty {
        try database.execute(
          sql: "INSERT INTO \(answerTable) (week_start, prompt, answer) VALUES (?, ?, ?)", arguments: [week.isoString, prompt.rawValue, answer])
      }
      if let completed = review.completedAtMillis {
        try database.execute(sql: "INSERT INTO \(completionTable) (week_start, completed_at_millis) VALUES (?, ?)", arguments: [week.isoString, completed])
      }
    }
  }

  /// Drops both tables, every week's answers and completion with them. A vault reset must call it.
  public static func clear(in database: Database) throws {
    try database.execute(sql: "DROP TABLE IF EXISTS \(answerTable)")
    try database.execute(sql: "DROP TABLE IF EXISTS \(completionTable)")
  }

  private static func write(week: LocalDate, in stores: MemoirStores, _ body: @escaping @Sendable (Database) throws -> Void) async throws(MemoirReadError) {
    try await readCall { () async throws(StoreError) in
      try await stores.main.write { transaction in
        let database = transaction.database
        try MemoirProjectionSQL.run {
          for definition in definitions { try database.execute(sql: definition) }
          try database.execute(sql: "DELETE FROM \(answerTable) WHERE week_start <> ?", arguments: [week.isoString])
          try database.execute(sql: "DELETE FROM \(completionTable) WHERE week_start <> ?", arguments: [week.isoString])
          try body(database)
        }
      }
    }
  }
}
