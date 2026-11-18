import Foundation
import GRDB
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/database/schemas/ai.ts:98
public enum WriterAttemptRole: String, CaseIterable, Codable, Sendable {
  case draft
  case repair
  case rewrite
  case revise
  case passage
}

public struct WriterSnapshotMessage: Codable, Equatable, Sendable {
  public let role: String
  public let content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

public struct WriterSnapshotRoute: Codable, Equatable, Sendable {
  public let provider: String
  public let model: String

  public init(provider: String, model: String) {
    self.provider = provider
    self.model = model
  }
}

/// One writer attempt as it was sent (writer-snapshot.service.ts:21-35): `revision` is the draft revision the attempt's output was saved as, and `attempt`
/// numbers the writer attempts of one run. `keptBack` counts what the disclosure policy withheld and what the pack cut, never the withheld text.
struct WriterSnapshotCapture: Codable, Equatable, Sendable {
  let novel: UUID
  let chapter: Int
  let revision: String
  let attempt: Int
  let role: WriterAttemptRole
  let messages: [WriterSnapshotMessage]
  let keptBack: JSONValue
  let planRevision: String?
  let bibleHash: String?
  let promptKey: String
  let promptVersion: String
  let route: WriterSnapshotRoute
  let isolated: Bool
  let run: String?
}

public struct WriterSnapshotSummary: Equatable, Sendable {
  public let id: UUID
  public let chapter: Int
  public let revision: String
  public let attempt: Int
  public let role: WriterAttemptRole
  public let promptKey: String
  public let promptVersion: String
  public let route: WriterSnapshotRoute
  public let isolated: Bool
  public let recordedAt: Date
}

/// The writer's view of one attempt; an isolated chapter's messages and Story Bible hash are walled off, never rebuilt from today's state.
public struct WriterSnapshotView: Equatable, Sendable {
  public let summary: WriterSnapshotSummary
  public let messages: [WriterSnapshotMessage]
  public let keptBack: JSONValue
  public let planRevision: String?
  public let bibleHash: String?
}

/// `nf_local_writer_snapshot`, the Inspector's writer attempts: they stay on the device that made the call (plan, Inspector), for the chapter's current
/// revision and the two before it, in the order revisions were first captured here.
enum WriterSnapshots {
  static let table = "nf_local_writer_snapshot"
  // writer-snapshot.service.ts:19
  static let retainedPriorRevisions = 2
  // writer-snapshot.service.ts:14-16
  static let walledOff = [
    WriterSnapshotMessage(role: "system", content: "Prose: walled off. This is an unrestricted chapter, so the messages it sent are not available here.")
  ]
  private static let definitions = [
    """
    CREATE TABLE IF NOT EXISTS nf_local_writer_snapshot (
      id BLOB NOT NULL PRIMARY KEY, novel BLOB NOT NULL, chapter INTEGER NOT NULL, revision TEXT NOT NULL, revision_order INTEGER NOT NULL,
      attempt INTEGER NOT NULL, recorded_at INTEGER NOT NULL, capture BLOB NOT NULL
    ) STRICT, WITHOUT ROWID
    """,
    "CREATE INDEX IF NOT EXISTS nf_local_writer_snapshot_chapter ON nf_local_writer_snapshot (novel, chapter, revision_order)",
  ]

  /// Never fails the run it captures (writer-snapshot.service.ts:89-101): the caller logs a failed capture and goes on.
  // writer-snapshot.service.ts:103-139
  static func record(_ capture: WriterSnapshotCapture, id: UUID, at now: Date, in database: Database) throws(StoreError) {
    do {
      for definition in definitions { try database.execute(sql: definition) }
      let (novel, chapter) = (capture.novel, capture.chapter)
      let seen = try Int.fetchOne(
        database, sql: "SELECT MIN(revision_order) FROM \(table) WHERE novel = ? AND chapter = ? AND revision = ?", arguments: [novel, chapter, capture.revision])
      let latest = try Int.fetchOne(database, sql: "SELECT MAX(revision_order) FROM \(table) WHERE novel = ? AND chapter = ?", arguments: [novel, chapter])
      let order = seen ?? (latest ?? 0) + 1
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (id, novel, chapter, revision, revision_order, attempt, recorded_at, capture) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        arguments: [id, novel, chapter, capture.revision, order, capture.attempt, milliseconds(now), try encoded(capture)])
      try database.execute(
        sql: "DELETE FROM \(table) WHERE novel = ? AND chapter = ? AND revision_order < ?", arguments: [novel, chapter, order - retainedPriorRevisions])
    } catch {
      throw StoreError(projecting: error)
    }
  }

  // writer-snapshot.service.ts:141-160
  static func list(novel: UUID, chapter: Int, in database: Database) throws(StoreError) -> [WriterSnapshotSummary] {
    try rows(sql: "WHERE novel = ? AND chapter = ? ORDER BY revision_order DESC, attempt DESC, recorded_at DESC, id", [novel, chapter], in: database).map(\.summary)
  }

  /// Nil for an id this device has no attempt under (WSN_001); `currentlyIsolated` is the chapter's isolation now, which walls off an older attempt too.
  // writer-snapshot.service.ts:163-186
  static func view(_ id: UUID, novel: UUID, currentlyIsolated: Bool, in database: Database) throws(StoreError) -> WriterSnapshotView? {
    guard let row = try rows(sql: "WHERE id = ? AND novel = ?", [id, novel], in: database).first else { return nil }
    let walled = row.capture.isolated || currentlyIsolated
    let summary = row.summary
    return WriterSnapshotView(
      summary: WriterSnapshotSummary(
        id: summary.id, chapter: summary.chapter, revision: summary.revision, attempt: summary.attempt, role: summary.role, promptKey: summary.promptKey,
        promptVersion: summary.promptVersion, route: summary.route, isolated: walled, recordedAt: summary.recordedAt),
      messages: walled ? walledOff : row.capture.messages, keptBack: row.capture.keptBack, planRevision: row.capture.planRevision,
      bibleHash: walled ? nil : row.capture.bibleHash)
  }

  /// With its novel, so a deleted novel leaves no attempt behind.
  static func forget(novel: UUID, in database: Database) throws(StoreError) {
    do {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE novel = ?", arguments: [novel])
    } catch {
      throw StoreError(projecting: error)
    }
  }

  private struct Stored {
    let id: UUID
    let recordedAt: Date
    let capture: WriterSnapshotCapture

    var summary: WriterSnapshotSummary {
      WriterSnapshotSummary(
        id: id, chapter: capture.chapter, revision: capture.revision, attempt: capture.attempt, role: capture.role, promptKey: capture.promptKey,
        promptVersion: capture.promptVersion, route: capture.route, isolated: capture.isolated, recordedAt: recordedAt)
    }
  }

  /// A row this version cannot decode is left out, as the Inspector shows nothing it cannot read.
  private static func rows(sql filter: String, _ arguments: [any DatabaseValueConvertible], in database: Database) throws(StoreError) -> [Stored] {
    do {
      guard try database.tableExists(table) else { return [] }
      return try Row.fetchAll(database, sql: "SELECT id, recorded_at, capture FROM \(table) \(filter)", arguments: StatementArguments(arguments)).compactMap { row in
        guard let id = try? row.decode(UUID.self, forColumn: "id"), let millis = try? row.decode(Int64.self, forColumn: "recorded_at"),
          let bytes = try? row.decode(Data.self, forColumn: "capture"), let capture = try? JSONDecoder().decode(WriterSnapshotCapture.self, from: bytes)
        else { return nil }
        return Stored(id: id, recordedAt: Date(timeIntervalSince1970: Double(millis) / 1000), capture: capture)
      }
    } catch {
      throw StoreError(projecting: error)
    }
  }

  private static func encoded(_ capture: WriterSnapshotCapture) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(capture)
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0
  }
}

extension VaultStore {
  /// The writer attempts this device keeps for the chapter, newest revision first.
  public func writerSnapshots(novel: UUID, chapter: Int) async throws(StoreError) -> [WriterSnapshotSummary] {
    try await read { transaction in try WriterSnapshots.list(novel: novel, chapter: chapter, in: transaction.database) }
  }

  public func writerSnapshot(_ id: UUID, novel: UUID, chapter: Int) async throws(StoreError) -> WriterSnapshotView? {
    try await read { transaction in
      try WriterSnapshots.view(id, novel: novel, currentlyIsolated: try currentIsolation(novel: novel, chapter: chapter, in: transaction), in: transaction.database)
        .flatMap { $0.summary.chapter == chapter ? $0 : nil }
    }
  }

  /// review-records.ts:125-136: the draft's flag while a draft exists, else the final chapter's; one this device cannot read counts as isolated.
  private func currentIsolation(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    guard let draft = try? DraftRecord.ref(novel: novel, chapter: chapter), let final = try? FinalChapterRecord.ref(novel: novel, chapter: chapter) else { return true }
    switch try DraftRecord.readHead(draft, in: transaction) {
    case .readable(let entry): return entry.record.content.isolated
    case .unreadable: return true
    case .absent: break
    }
    switch try FinalChapterRecord.read(final, in: transaction) {
    case .readable(let entry): return entry.record.canon.isolated
    case .unreadable: return true
    case .absent: return false
    }
  }
}
