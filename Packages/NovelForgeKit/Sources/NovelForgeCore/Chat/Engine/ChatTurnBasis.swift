import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The exchange a keyed turn records with its reply: the segment it continues or opens, and the sections its context update leaves the model holding.
struct ChatExchangePlan: Equatable, Sendable {
  let segment: String
  let opening: ChatSegmentOpening?
  let sections: ChatHeldSections
}

/// Everything a turn sends besides its rounds, fixed when the author's message is saved, so a resumed turn on this device asks again exactly what it first
/// asked (orchestrator decision 6) and a retry answers the message as it was sent.
struct ChatTurnBasis: Equatable, Sendable {
  let turn: UUID
  let novel: UUID
  let session: UUID
  let userMessage: UUID
  /// The newest message the turn's history held.
  let seen: UUID?
  let contentMode: ContentMode
  let costTier: CostTier
  let thinksDeeper: Bool
  let justDiscussing: Bool
  let proseEdits: Bool
  let sessionMode: RefinementChatMode
  let organiseRequest: Bool
  let organise: OrganiseRouting
  let content: String
  let contexts: [ChatPassageContext]
  let stableContext: String
  let history: [PromptMessage]
  let parts: TurnMessageParts
  let exchange: ChatExchangePlan?
  /// The ledger ids of the compaction that ran before the turn.
  let compactionCalls: [UUID]
  /// The author's message opens the session on this device, so the turn names the session beside its run, and again when it resumes (chat.service.ts:331).
  let namesSession: Bool

  var reply: UUID { turn }
  var authorWords: String { NovelForgeCore.authorWords(content, contexts: contexts) }
}

/// The turn's answer once its guards ran, saved before anything is staged so a resumed or retried turn never asks the model again for an answer that may
/// already have applied changes.
struct ChatTurnSettled: Equatable, Sendable {
  let reply: String
  let changeSet: [OrderedJSONObject]?
  let question: ChatQuestion?
  let warnings: [String]
  let trace: JSONValue
  let calls: [UUID]
  let exchangeMessages: [PromptMessage]
}

/// What staging left for the reply, saved before the reply is appended.
struct ChatTurnStaged: Equatable, Sendable {
  let appliedProposal: UUID?
  let cardProposal: UUID?
  let applyNote: String?
  let held: String?
  let replyNote: String?
}

/// What the engine keeps across lookup rounds in a `LocalTurnCheckpoint`'s carry: the tools called (to rebuild `ChatLookupCounts`), whether a planner-only
/// page was read, the trace's sources and the ledger ids spent so far.
struct ChatTurnCarry: Equatable, Sendable {
  var tools: [String] = []
  var readPlannerOnly = false
  var sources: [TurnTraceSource] = []
  var calls: [UUID] = []

  var json: JSONValue {
    .object([
      "tools": .array(tools.map(JSONValue.string)), "planner": .bool(readPlannerOnly), "sources": .array(sources.map(\.json)),
      "calls": .array(calls.map { .string($0.uuidString) }),
    ])
  }

  init() {}

  init?(json: JSONValue) {
    guard let fields = json.objectValue, let tools = fields["tools"]?.arrayValue, let planner = fields["planner"]?.boolValue,
      let sources = fields["sources"]?.arrayValue, let calls = fields["calls"]?.arrayValue
    else { return nil }
    let names = tools.compactMap(\.stringValue)
    let traced = sources.compactMap(TurnTraceSource.init(json:))
    let ids = calls.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
    guard names.count == tools.count, traced.count == sources.count, ids.count == calls.count else { return nil }
    self.tools = names
    readPlannerOnly = planner
    self.sources = traced
    self.calls = ids
  }
}

struct ChatTurnRecord: Sendable {
  let basis: ChatTurnBasis
  let settled: ChatTurnSettled?
  let staged: ChatTurnStaged?
}

/// The turn records this device keeps beside its local turns, in a table of the app's own: nothing in it syncs, and each row goes with the reply's
/// transaction. A row that cannot be read is no record, so its turn is not resumed.
enum ChatTurnRecords {
  static let table = "nf_local_turn_basis"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_turn_basis (
      turn BLOB NOT NULL PRIMARY KEY, session BLOB NOT NULL, basis BLOB NOT NULL, settled BLOB, staged BLOB
    ) STRICT, WITHOUT ROWID
    """

  /// A retry that asks again replaces the basis and forgets what the earlier attempt settled.
  static func save(_ basis: ChatTurnBasis, in database: Database) throws(StoreError) {
    try execute {
      try database.execute(sql: definition)
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (turn, session, basis) VALUES (?, ?, ?)", arguments: [basis.turn, basis.session, CanonicalJSON.encode(basis.json)])
    }
  }

  static func settle(_ turn: UUID, _ settled: ChatTurnSettled, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "UPDATE \(table) SET settled = ? WHERE turn = ?", arguments: [CanonicalJSON.encode(settled.json), turn])
    }
  }

  static func stage(_ turn: UUID, _ staged: ChatTurnStaged, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "UPDATE \(table) SET staged = ? WHERE turn = ?", arguments: [CanonicalJSON.encode(staged.json), turn])
    }
  }

  static func load(_ turn: UUID, in database: Database) throws(StoreError) -> ChatTurnRecord? {
    try execute {
      guard try database.tableExists(table), let row = try Row.fetchOne(database, sql: "SELECT basis, settled, staged FROM \(table) WHERE turn = ?", arguments: [turn]),
        let basis = decode(row, "basis").flatMap(ChatTurnBasis.init(json:))
      else { return nil }
      let settled = decode(row, "settled").map(ChatTurnSettled.init(json:))
      let staged = decode(row, "staged").map(ChatTurnStaged.init(json:))
      guard settled != .some(nil), staged != .some(nil) else { return nil }
      return ChatTurnRecord(basis: basis, settled: settled.flatMap { $0 }, staged: staged.flatMap { $0 })
    }
  }

  static func forget(_ turn: UUID, in database: Database) throws(StoreError) {
    try execute {
      if try database.tableExists(table) { try database.execute(sql: "DELETE FROM \(table) WHERE turn = ?", arguments: [turn]) }
    }
    try TurnStagingMarks.forget(turn: turn, in: database)
  }

  static func forget(session: UUID, in database: Database) throws(StoreError) {
    try execute {
      if try database.tableExists(table) { try database.execute(sql: "DELETE FROM \(table) WHERE session = ?", arguments: [session]) }
    }
    try TurnStagingMarks.forget(session: session, in: database)
  }

  /// Rows whose local turn is gone, as when a session's deletion cleared its turns.
  static func forgetOrphans(in database: Database) throws(StoreError) {
    try execute {
      let turns = try database.tableExists(LocalTurnStore.turnTable)
      for name in [table, TurnStagingMarks.table] where try database.tableExists(name) {
        try database.execute(sql: turns ? "DELETE FROM \(name) WHERE turn NOT IN (SELECT id FROM \(LocalTurnStore.turnTable))" : "DELETE FROM \(name)")
      }
    }
  }

  private static func decode(_ row: Row, _ column: String) -> JSONValue? {
    guard let bytes = try? row.decode(Data.self, forColumn: column) else { return (row[column] as DatabaseValue).isNull ? nil : .null }
    return (try? CanonicalJSON.decode(bytes)) ?? .null
  }

  private static func execute<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(projecting: error)
    }
  }
}

private func messagesJSON(_ messages: [PromptMessage]) -> JSONValue {
  .array(messages.map { .object(["role": .string($0.role.rawValue), "content": .string($0.text)]) })
}

private func messages(_ json: JSONValue?) -> [PromptMessage]? {
  guard let items = json?.arrayValue else { return nil }
  let read = items.compactMap { item -> PromptMessage? in
    guard let fields = item.objectValue, let role = fields["role"]?.stringValue.flatMap(PromptMessage.Role.init(rawValue:)), role != .system,
      let content = fields["content"]?.stringValue
    else { return nil }
    return PromptMessage(role, content)
  }
  return read.count == items.count ? read : nil
}

private func uuids(_ json: JSONValue?) -> [UUID]? {
  guard let items = json?.arrayValue else { return nil }
  let read = items.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
  return read.count == items.count ? read : nil
}

private func uuid(_ json: JSONValue?) -> UUID? {
  json?.stringValue.flatMap(UUID.init(uuidString:))
}

private func optional(_ value: String?) -> JSONValue {
  value.map(JSONValue.string) ?? .null
}

private func optional(_ value: UUID?) -> JSONValue {
  value.map { .string($0.uuidString) } ?? .null
}

private func optionalText(_ json: JSONValue?) -> String?? {
  switch json {
  case .null?: .some(nil)
  case .string(let text)?: .some(text)
  default: nil
  }
}

private func optionalID(_ json: JSONValue?) -> UUID?? {
  switch json {
  case .null?: .some(nil)
  case .string(let text)?: UUID(uuidString: text).map { .some($0) }
  default: nil
  }
}

extension OrganiseRouting {
  fileprivate var stored: String {
    switch self {
    case .none: "none"
    case .card: "card"
    case .start: "start"
    }
  }

  fileprivate init?(stored: String) {
    switch stored {
    case "none": self = .none
    case "card": self = .card
    case "start": self = .start
    default: return nil
    }
  }
}

extension ChatHeldSections {
  fileprivate var json: JSONValue {
    .array(entries.map { .object(["key": .string($0.key), "digest": .string($0.section.digest), "heading": .string($0.section.heading)]) })
  }

  fileprivate init?(json: JSONValue?) {
    guard let items = json?.arrayValue else { return nil }
    var entries = [(key: String, section: ChatHeldSection)]()
    for item in items {
      guard let fields = item.objectValue, let key = fields["key"]?.stringValue, let digest = fields["digest"]?.stringValue,
        let heading = fields["heading"]?.stringValue
      else { return nil }
      entries.append((key, ChatHeldSection(digest: digest, heading: heading)))
    }
    self.init(entries)
  }
}

extension ChatExchangePlan {
  fileprivate var json: JSONValue {
    var fields: [String: JSONValue] = ["segment": .string(segment), "sections": sections.json]
    if let opening {
      fields["opening"] = .object(["through": .string(opening.through), "playbook": .string(opening.playbook), "stableContext": .string(opening.stableContext)])
    }
    return .object(fields)
  }

  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let segment = fields["segment"]?.stringValue, let sections = ChatHeldSections(json: fields["sections"]) else { return nil }
    var opening: ChatSegmentOpening?
    if let stored = fields["opening"] {
      guard let entry = stored.objectValue, let through = entry["through"]?.stringValue, let playbook = entry["playbook"]?.stringValue,
        let stableContext = entry["stableContext"]?.stringValue
      else { return nil }
      opening = ChatSegmentOpening(through: through, playbook: playbook, stableContext: stableContext)
    }
    self.init(segment: segment, opening: opening, sections: sections)
  }
}

extension ChatTurnBasis {
  fileprivate var json: JSONValue {
    .object([
      "turn": .string(turn.uuidString), "novel": .string(novel.uuidString), "session": .string(session.uuidString), "userMessage": .string(userMessage.uuidString),
      "seen": optional(seen), "contentMode": .string(contentMode.rawValue), "costTier": .string(costTier.rawValue), "thinksDeeper": .bool(thinksDeeper),
      "justDiscussing": .bool(justDiscussing), "proseEdits": .bool(proseEdits), "sessionMode": .string(sessionMode.rawValue),
      "organiseRequest": .bool(organiseRequest), "organise": .string(organise.stored), "content": .string(content), "contexts": .array(contexts.map(\.json)),
      "stableContext": .string(stableContext), "history": messagesJSON(history), "volatileContext": .string(parts.volatileContext),
      "turnRules": .string(parts.turnRules), "renderedMessage": .string(parts.userMessage), "exchange": exchange?.json ?? .null,
      "compactionCalls": .array(compactionCalls.map { .string($0.uuidString) }), "namesSession": .bool(namesSession),
    ])
  }

  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let turn = uuid(fields["turn"]), let novel = uuid(fields["novel"]), let session = uuid(fields["session"]),
      let userMessage = uuid(fields["userMessage"]), let seen = optionalID(fields["seen"]),
      let contentMode = fields["contentMode"]?.stringValue.flatMap(ContentMode.init(rawValue:)),
      let costTier = fields["costTier"]?.stringValue.flatMap(CostTier.init(rawValue:)), let thinksDeeper = fields["thinksDeeper"]?.boolValue,
      let justDiscussing = fields["justDiscussing"]?.boolValue, let proseEdits = fields["proseEdits"]?.boolValue,
      let sessionMode = fields["sessionMode"]?.stringValue.flatMap(RefinementChatMode.init(rawValue:)), let organiseRequest = fields["organiseRequest"]?.boolValue,
      let organise = fields["organise"]?.stringValue.flatMap(OrganiseRouting.init(stored:)), let content = fields["content"]?.stringValue,
      let storedContexts = fields["contexts"]?.arrayValue, let stableContext = fields["stableContext"]?.stringValue, let history = messages(fields["history"]),
      let volatileContext = fields["volatileContext"]?.stringValue, let turnRules = fields["turnRules"]?.stringValue,
      let rendered = fields["renderedMessage"]?.stringValue, let compactionCalls = uuids(fields["compactionCalls"]),
      let namesSession = fields["namesSession"]?.boolValue
    else { return nil }
    let contexts = storedContexts.compactMap(ChatPassageContext.init(json:))
    guard contexts.count == storedContexts.count else { return nil }
    var exchange: ChatExchangePlan?
    if let stored = fields["exchange"], !stored.isNull {
      guard let plan = ChatExchangePlan(json: stored) else { return nil }
      exchange = plan
    }
    self.init(
      turn: turn, novel: novel, session: session, userMessage: userMessage, seen: seen, contentMode: contentMode, costTier: costTier, thinksDeeper: thinksDeeper,
      justDiscussing: justDiscussing, proseEdits: proseEdits, sessionMode: sessionMode, organiseRequest: organiseRequest, organise: organise, content: content,
      contexts: contexts, stableContext: stableContext, history: history,
      parts: TurnMessageParts(volatileContext: volatileContext, turnRules: turnRules, userMessage: rendered), exchange: exchange, compactionCalls: compactionCalls,
      namesSession: namesSession)
  }
}

extension ChatTurnSettled {
  fileprivate var json: JSONValue {
    .object([
      "reply": .string(reply), "changeSet": changeSet.map { .string(OrderedJSON.array($0.map(OrderedJSON.object)).jsonText) } ?? .null,
      "question": question?.stored ?? .null, "warnings": .array(warnings.map(JSONValue.string)), "trace": trace,
      "calls": .array(calls.map { .string($0.uuidString) }), "exchangeMessages": messagesJSON(exchangeMessages),
    ])
  }

  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let reply = fields["reply"]?.stringValue, let storedWarnings = fields["warnings"]?.arrayValue,
      let trace = fields["trace"], let calls = uuids(fields["calls"]), let exchangeMessages = messages(fields["exchangeMessages"])
    else { return nil }
    let warnings = storedWarnings.compactMap(\.stringValue)
    guard warnings.count == storedWarnings.count else { return nil }
    var changeSet: [OrderedJSONObject]?
    if let text = fields["changeSet"]?.stringValue {
      guard let items = (try? OrderedJSON(parsing: text))?.arrayValue else { return nil }
      let objects = items.compactMap(\.objectValue)
      guard objects.count == items.count else { return nil }
      changeSet = objects
    }
    var question: ChatQuestion?
    if let stored = fields["question"], !stored.isNull {
      guard let card = ChatQuestion(stored: stored) else { return nil }
      question = card
    }
    self.init(reply: reply, changeSet: changeSet, question: question, warnings: warnings, trace: trace, calls: calls, exchangeMessages: exchangeMessages)
  }
}

extension ChatTurnStaged {
  fileprivate var json: JSONValue {
    .object([
      "appliedProposal": optional(appliedProposal), "cardProposal": optional(cardProposal), "applyNote": optional(applyNote), "held": optional(held),
      "replyNote": optional(replyNote),
    ])
  }

  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let applied = optionalID(fields["appliedProposal"]), let card = optionalID(fields["cardProposal"]),
      let applyNote = optionalText(fields["applyNote"]), let held = optionalText(fields["held"]), let replyNote = optionalText(fields["replyNote"])
    else { return nil }
    self.init(appliedProposal: applied, cardProposal: card, applyNote: applyNote, held: held, replyNote: replyNote)
  }
}
