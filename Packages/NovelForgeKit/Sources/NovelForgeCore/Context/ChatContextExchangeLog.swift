import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// What each reply's turn sent, kept on this device only (orchestrator decision 8): the next turn here replays its segment so the model's cached prefix holds,
/// while another device, holding none, sends the plain history. A table of the app's own beside the vault, written through the write transaction's database:
/// nothing in it syncs, and a reset of the derived tables leaves it alone.
enum ChatContextExchangeLog {
  static let table = "nf_local_chat_segment"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_chat_segment (
      session BLOB NOT NULL, reply BLOB NOT NULL, exchange BLOB NOT NULL, PRIMARY KEY (session, reply)
    ) STRICT, WITHOUT ROWID
    """

  /// Written in the transaction that appends the reply (apps/novel-forge-server/src/modules/refinement/chat.service.ts:398-405).
  static func record(_ exchange: ChatExchange, reply: UUID, session: UUID, in database: Database) throws(StoreError) {
    do {
      try database.execute(sql: definition)
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (session, reply, exchange) VALUES (?, ?, ?)", arguments: [session, reply, CanonicalJSON.encode(exchange.json)])
    } catch {
      throw StoreError(projecting: error)
    }
  }

  /// The exchanges this device recorded for the session's replies, by reply. When any of them cannot be read none is returned, so the session's next turn sends
  /// the plain history: a segment missing one turn would replay that turn as plain history while later updates assume the model saw what it sent.
  static func load(session: UUID, in database: Database) throws(StoreError) -> [UUID: ChatExchange] {
    do {
      guard try database.tableExists(table) else { return [:] }
      var exchanges = [UUID: ChatExchange]()
      for row in try Row.fetchAll(database, sql: "SELECT reply, exchange FROM \(table) WHERE session = ?", arguments: [session]) {
        guard let reply = try? row.decode(UUID.self, forColumn: "reply"), let bytes = try? row.decode(Data.self, forColumn: "exchange"),
          let json = try? CanonicalJSON.decode(bytes), let exchange = ChatExchange(json: json)
        else { return [:] }
        exchanges[reply] = exchange
      }
      return exchanges
    } catch {
      throw StoreError(projecting: error)
    }
  }

  /// A compaction ends every segment the session opened before it, so none of its exchanges is replayed again (chat-compaction.service.ts:169-173).
  static func forget(session: UUID, in database: Database) throws(StoreError) {
    do {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE session = ?", arguments: [session])
    } catch {
      throw StoreError(projecting: error)
    }
  }
}

extension ChatExchange {
  fileprivate var json: JSONValue {
    var fields: [String: JSONValue] = [
      "segment": .string(segment),
      "sections": .array(sections.entries.map { .object(["key": .string($0.key), "digest": .string($0.section.digest), "heading": .string($0.section.heading)]) }),
      "messages": .array(messages.map { .object(["role": .string($0.role.rawValue), "content": .string($0.text)]) }),
    ]
    if let opening {
      fields["opening"] = .object([
        "through": .string(opening.through), "playbook": .string(opening.playbook), "stableContext": .string(opening.stableContext),
      ])
    }
    return .object(fields)
  }

  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let segment = fields["segment"]?.stringValue, let storedSections = fields["sections"]?.arrayValue,
      let storedMessages = fields["messages"]?.arrayValue
    else { return nil }
    var sections = [(key: String, section: ChatHeldSection)]()
    for stored in storedSections {
      guard let entry = stored.objectValue, let key = entry["key"]?.stringValue, let digest = entry["digest"]?.stringValue,
        let heading = entry["heading"]?.stringValue
      else { return nil }
      sections.append((key, ChatHeldSection(digest: digest, heading: heading)))
    }
    var messages = [PromptMessage]()
    for stored in storedMessages {
      guard let entry = stored.objectValue, let role = entry["role"]?.stringValue.flatMap(PromptMessage.Role.init(rawValue:)), role != .system,
        let content = entry["content"]?.stringValue
      else { return nil }
      messages.append(PromptMessage(role, content))
    }
    var opening: ChatSegmentOpening?
    if let stored = fields["opening"] {
      guard let entry = stored.objectValue, let through = entry["through"]?.stringValue, let playbook = entry["playbook"]?.stringValue,
        let stableContext = entry["stableContext"]?.stringValue
      else { return nil }
      opening = ChatSegmentOpening(through: through, playbook: playbook, stableContext: stableContext)
    }
    self.init(segment: segment, opening: opening, sections: ChatHeldSections(sections), messages: messages)
  }
}
