import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore

/// The last request a chat turn sent, exactly as the provider received it, for the Inspector. It stays on the device that made the call (the plan's
/// Inspector); other devices have none.
public struct ChatCallInspection: Sendable, Equatable {
  public struct Message: Sendable, Equatable {
    public let role: String
    public let text: String
  }

  public let turn: UUID
  public let recordedAt: Date
  public let model: String
  public let system: [String]
  /// The index of the system segment the cache breakpoint follows, when one does.
  public let stablePrefixEnd: Int?
  public let messages: [Message]
  public let maxOutputTokens: Int
  public let effort: String?
  public let attempt: Int
  public let isRepair: Bool
}

/// `nf_local_call_inspector`: one row per turn, keyed by the turn's id (which its reply carries), replaced by each later request of the turn. A table of the
/// app's own beside the vault: nothing in it syncs. Each session keeps its newest `keptPerSession` rows.
enum ChatCallInspector {
  static let table = "nf_local_call_inspector"
  static let keptPerSession = 20
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_call_inspector (
      turn BLOB NOT NULL PRIMARY KEY, session BLOB NOT NULL, recorded_at INTEGER NOT NULL, request BLOB NOT NULL
    ) STRICT, WITHOUT ROWID
    """

  static func record(_ attempt: StructuredAttempt, turn: UUID, session: UUID, at now: Date, in database: Database) throws(StoreError) {
    let request = attempt.request
    let json: JSONValue = .object([
      "model": .string(request.model), "system": .array(request.system.map { .string($0.text) }),
      "stablePrefixEnd": request.system.firstIndex(where: \.endsStablePrefix).map { .int(Int64($0)) } ?? .null,
      "messages": .array(request.messages.map { .object(["role": .string($0.role.rawValue), "text": .string($0.text)]) }),
      "maxOutputTokens": .int(Int64(request.maxOutputTokens)), "effort": request.effort.map { .string($0.rawValue) } ?? .null,
      "attempt": .int(Int64(attempt.number)), "repair": .bool(attempt.purpose != .answer),
    ])
    do {
      try database.execute(sql: definition)
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (turn, session, recorded_at, request) VALUES (?, ?, ?, ?)",
        arguments: [turn, session, Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0, CanonicalJSON.encode(json)])
      try database.execute(
        sql: """
          DELETE FROM \(table) WHERE session = ? AND turn NOT IN (SELECT turn FROM \(table) WHERE session = ? ORDER BY recorded_at DESC, turn DESC LIMIT ?)
          """, arguments: [session, session, keptPerSession])
    } catch {
      throw StoreError(projecting: error)
    }
  }

  static func inspection(of turn: UUID, in database: Database) throws(StoreError) -> ChatCallInspection? {
    do {
      guard try database.tableExists(table), let row = try Row.fetchOne(database, sql: "SELECT recorded_at, request FROM \(table) WHERE turn = ?", arguments: [turn]),
        let millis = try? row.decode(Int64.self, forColumn: "recorded_at"), let bytes = try? row.decode(Data.self, forColumn: "request"),
        let fields = (try? CanonicalJSON.decode(bytes))?.objectValue
      else { return nil }
      return inspection(turn, at: Date(timeIntervalSince1970: Double(millis) / 1000), fields)
    } catch {
      throw StoreError(projecting: error)
    }
  }

  /// For a deleted session or novel: the Inspector keeps nothing of a chat that is gone.
  static func forget(session: UUID, in database: Database) throws(StoreError) {
    do {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE session = ?", arguments: [session])
    } catch {
      throw StoreError(projecting: error)
    }
  }

  private static func inspection(_ turn: UUID, at recordedAt: Date, _ fields: [String: JSONValue]) -> ChatCallInspection? {
    guard let model = fields["model"]?.stringValue, let system = fields["system"]?.arrayValue?.compactMap(\.stringValue),
      let storedMessages = fields["messages"]?.arrayValue, let maxOutputTokens = fields["maxOutputTokens"]?.intValue.flatMap({ Int(exactly: $0) }),
      let attempt = fields["attempt"]?.intValue.flatMap({ Int(exactly: $0) }), let repair = fields["repair"]?.boolValue
    else { return nil }
    let messages = storedMessages.compactMap { stored -> ChatCallInspection.Message? in
      guard let entry = stored.objectValue, let role = entry["role"]?.stringValue, let text = entry["text"]?.stringValue else { return nil }
      return ChatCallInspection.Message(role: role, text: text)
    }
    return ChatCallInspection(
      turn: turn, recordedAt: recordedAt, model: model, system: system, stablePrefixEnd: fields["stablePrefixEnd"]?.intValue.flatMap { Int(exactly: $0) },
      messages: messages, maxOutputTokens: maxOutputTokens, effort: fields["effort"]?.stringValue, attempt: attempt, isRepair: repair)
  }
}

extension VaultStore {
  /// The last request the turn whose reply is `reply` sent, when this device made it.
  public func chatCallInspection(reply: UUID) async throws(StoreError) -> ChatCallInspection? {
    try await read { transaction in try ChatCallInspector.inspection(of: reply, in: transaction.database) }
  }
}
