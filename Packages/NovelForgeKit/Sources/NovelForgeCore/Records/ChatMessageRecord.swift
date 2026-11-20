import Foundation
import ShadowCore
import ShadowStore
import ShadowText

extension ChatMessageMember: FieldName {}

// Reading is total and lossless: `contexts` and `question` keep their stored JSON even when it cannot be decoded, and `hasUnreadableContexts` / `hasUnreadableQuestion` say so.
// Consumers fail closed: the hard-line screen and compaction refuse or skip a message with unreadable contexts, and renderers show its text with a "passage could not be shown" marker.
// apps/novel-forge-server/src/database/schemas/refinement.ts:189-226; the ordinal, run id, model name and exchange are replaced by `seen`, the call ids and the local turn store
public struct ChatMessageRecord: AppendedRecord {
  public static let kind = NovelForgeKind.chatMessage
  public static let novelMember = ChatMessageMember.novel

  public let id: UUID
  public let novel: UUID
  public let session: UUID
  public let role: StoredEnum<ChatRole>
  public let content: String
  let storedContexts: JSONValue?
  public let answers: UUID?
  public let seen: UUID?
  public let pace: StoredEnum<CostTier>?
  public let deeper: Bool?
  public let contentMode: StoredEnum<ContentMode>?
  public let justDiscussing: Bool?
  public let proseEdits: Bool?
  public let tokens: Int?
  public let question: JSONValue?
  public let trace: JSONValue?
  public let modelCalls: [UUID]?
  public let appliedProposal: UUID?
  public let cardProposal: UUID?
  public let applyNote: String?
  public let held: String?
  public private(set) var unrecognised: [String: JSONValue]

  // apps/novel-forge-server/src/modules/refinement/chat.service.ts:274 refuses an author message with neither text nor passages; an empty passage list is stored as none (:436)
  public init(
    id: UUID = UUID(), novel: UUID, session: UUID, role: ChatRole, content: String, contexts: [JSONValue]? = nil, answers: UUID? = nil, seen: UUID? = nil, pace: CostTier? = nil,
    deeper: Bool? = nil, contentMode: ContentMode? = nil, justDiscussing: Bool? = nil, proseEdits: Bool? = nil, tokens: Int? = nil,
    question: JSONValue? = nil, trace: JSONValue? = nil,
    modelCalls: [UUID]? = nil, appliedProposal: UUID? = nil, cardProposal: UUID? = nil, applyNote: String? = nil, held: String? = nil
  ) throws(ChatRecordError) {
    let contexts = contexts?.isEmpty == true ? nil : contexts
    let (question, trace) = (question?.isNull == true ? nil : question, trace?.isNull == true ? nil : trace)
    if role == .user {
      guard content.unicodeScalars.count <= maxChatTurnCharacters else { throw .contentTooLong(limit: maxChatTurnCharacters) }
      guard !content.jsTrim().isEmpty || contexts != nil else { throw .emptyMessage }
    }
    if let contexts {
      guard contexts.count <= maxPassageContexts else { throw .tooManyContexts(limit: maxPassageContexts) }
      if let index = contexts.firstIndex(where: { ChatPassageContext(json: $0) == nil }) { throw .malformedContext(index: index) }
    }
    if let question {
      guard let card = ChatQuestion(stored: question), card.isCard else { throw .malformedQuestion }
    }
    self.init(
      unvalidated: id, novel: novel, session: session, role: .known(role), content: content, storedContexts: contexts.map { .array($0) }, answers: answers, seen: seen,
      pace: pace.map { .known($0) },
      deeper: deeper, contentMode: contentMode.map { .known($0) }, justDiscussing: justDiscussing, proseEdits: proseEdits, tokens: tokens, question: question, trace: trace,
      modelCalls: modelCalls, appliedProposal: appliedProposal, cardProposal: cardProposal, applyNote: applyNote, held: held)
  }

  private init(
    unvalidated id: UUID, novel: UUID, session: UUID, role: StoredEnum<ChatRole>, content: String, storedContexts: JSONValue?, answers: UUID?, seen: UUID?,
    pace: StoredEnum<CostTier>?,
    deeper: Bool?, contentMode: StoredEnum<ContentMode>?, justDiscussing: Bool?, proseEdits: Bool?, tokens: Int?, question: JSONValue?, trace: JSONValue?, modelCalls: [UUID]?,
    appliedProposal: UUID?, cardProposal: UUID?, applyNote: String?, held: String?
  ) {
    self.id = id
    self.novel = novel
    self.session = session
    self.role = role
    self.content = content
    self.storedContexts = storedContexts
    self.answers = answers
    self.seen = seen
    self.pace = pace
    self.deeper = deeper
    self.contentMode = contentMode
    self.justDiscussing = justDiscussing
    self.proseEdits = proseEdits
    self.tokens = tokens
    self.question = question
    self.trace = trace
    self.modelCalls = modelCalls
    self.appliedProposal = appliedProposal
    self.cardProposal = cardProposal
    self.applyNote = applyNote
    self.held = held
    unrecognised = [:]
  }

  public init(id: UUID, reading reader: FieldReader<ChatMessageMember>) throws(UnreadableReason) {
    let question: JSONValue? = try reader.optional(.question)
    self.init(
      unvalidated: id, novel: try reader.required(.novel), session: try reader.required(.session), role: try reader.required(.role), content: try reader.required(.content),
      storedContexts: try reader.optional(.contexts), answers: try reader.optional(.answers), seen: try reader.optional(.seen), pace: try reader.optional(.pace),
      deeper: try reader.optional(.deeper),
      contentMode: try reader.optional(.contentMode), justDiscussing: try reader.optional(.justDiscussing), proseEdits: try reader.optional(.proseEdits),
      tokens: try reader.optional(.tokens), question: question, trace: try reader.optional(.trace), modelCalls: try reader.optional(.modelCalls),
      appliedProposal: try reader.optional(.appliedProposal), cardProposal: try reader.optional(.cardProposal), applyNote: try reader.optional(.applyNote),
      held: try reader.optional(.held))
    unrecognised = reader.unrecognised
  }

  public var contexts: [JSONValue]? { storedContexts?.arrayValue }

  var passageContexts: [ChatPassageContext]? { contexts?.compactMap { ChatPassageContext(json: $0) } }

  var hasUnreadableContexts: Bool {
    guard let storedContexts else { return false }
    guard let items = storedContexts.arrayValue else { return true }
    return items.contains { ChatPassageContext(json: $0) == nil }
  }

  public var questionCard: ChatQuestion? { question.flatMap { ChatQuestion(stored: $0) } }

  var hasUnreadableQuestion: Bool { question.map { ChatQuestion(stored: $0) == nil } == true }

  init(
    id: UUID = UUID(), novel: UUID, session: UUID, role: ChatRole, content: String, passageContexts: [ChatPassageContext], answers: UUID? = nil, seen: UUID? = nil,
    pace: CostTier? = nil, deeper: Bool? = nil, contentMode: ContentMode? = nil, justDiscussing: Bool? = nil, proseEdits: Bool? = nil, tokens: Int? = nil,
    question: ChatQuestion? = nil, trace: JSONValue? = nil, modelCalls: [UUID]? = nil, appliedProposal: UUID? = nil, cardProposal: UUID? = nil, applyNote: String? = nil,
    held: String? = nil
  ) throws(ChatRecordError) {
    try self.init(
      id: id, novel: novel, session: session, role: role, content: content, contexts: passageContexts.map(\.json), answers: answers, seen: seen, pace: pace, deeper: deeper,
      contentMode: contentMode, justDiscussing: justDiscussing, proseEdits: proseEdits, tokens: tokens, question: question?.stored, trace: trace, modelCalls: modelCalls,
      appliedProposal: appliedProposal, cardProposal: cardProposal, applyNote: applyNote, held: held)
  }

  public var members: RecordFields<ChatMessageMember> {
    var fields = RecordFields<ChatMessageMember>()
    fields.put(.novel, novel)
    fields.put(.session, session)
    fields.put(.role, role)
    fields.put(.content, content)
    fields.put(.contexts, storedContexts)
    fields.put(.answers, answers)
    fields.put(.seen, seen)
    fields.put(.pace, pace)
    fields.put(.deeper, deeper)
    fields.put(.contentMode, contentMode)
    fields.put(.justDiscussing, justDiscussing)
    fields.put(.proseEdits, proseEdits)
    fields.put(.tokens, tokens)
    fields.put(.question, question)
    fields.put(.trace, trace)
    fields.put(.modelCalls, modelCalls)
    fields.put(.appliedProposal, appliedProposal)
    fields.put(.cardProposal, cardProposal)
    fields.put(.applyNote, applyNote)
    fields.put(.held, held)
    return fields
  }
}

extension ChatMessageRecord {
  public static func listing<Transaction: StateReading & ~Copyable>(session: UUID, novel: UUID, in transaction: borrowing Transaction) throws(StoreError)
    -> AppendedListing<ChatMessageRecord>
  {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: novel) { reader in
      let stored: UUID? = try? reader.required(.session)
      return stored.map { $0 == session } ?? true
    }
  }
}
