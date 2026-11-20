import Foundation
import GRDB
import OSLog
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowText

/// The turn whose opening message names the session: its pace routes the call and its content mode decides whether the hard line holds it.
struct ChatAutoTitleTurn: Equatable, Sendable {
  let pace: Pace
  let contentMode: ContentMode
  let consent: AIConsentRequirement
}

enum ChatAutoTitleOutcome: Equatable, Sendable {
  case named(String, callIDs: [UUID])
  /// No model was asked: the session is titled, named or gone, or the message is not its opening author message or is too short to name it.
  case skipped
  /// The model answered but nothing was written: the answer was blank or not a title, or a title arrived meanwhile.
  case kept(callIDs: [UUID])
  case refused(HardLineHit, callIDs: [UUID])
}

enum ChatAutoTitleError: ShadowError {
  case store(StoreError)
  case routing(TaskRouterError)
  /// `callIDs` are the ledger ids of the requests the failed call made, so the reply can carry their spend.
  case model(StructuredError, callIDs: [UUID])

  var code: String {
    switch self {
    case .store(let error): error.code
    case .routing(let error): error.code
    case .model(let error, _): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .store(let error): error.errorDescription
    case .routing(let error): error.errorDescription
    case .model(let error, _): error.errorDescription
    }
  }
}

/// apps/novel-forge-server/src/modules/refinement/chat-session.service.ts:139-172: names a session from its opening author message alone. The reference
/// writes `title` only while it is null; here the name goes into the first-writer-wins `auto_title`, beside the author's `title` register, so a rename made
/// on any device at any time wins, and two devices naming the session at once keep the first name. The caller runs it beside the turn, off the main actor,
/// and adds `callIDs` to the reply's model calls when it can (turn-cost.service.ts:17 folds the title run into the turn's cost).
enum ChatAutoTitle {
  private static let logger = Logger(category: "chat.title")
  // chat-session.service.ts:35
  static let minimumCharacters = 15
  // apps/novel-forge-server/src/modules/ai/defaults.ts:55
  private static let task = ModelTask.helper
  private static let role = "title"
  private static let schemaName = "chat-title"

  private struct Output: Decodable {
    let title: String
  }

  @concurrent
  static func name(session: UUID, novel: UUID, opening message: UUID, turn: ChatAutoTitleTurn, store: VaultStore, router: TaskRouter) async throws(ChatAutoTitleError)
    -> ChatAutoTitleOutcome
  {
    let read: String?
    do throws(StoreError) {
      read = try await store.read { transaction in try openingText(session: session, novel: novel, message: message, in: transaction) }
    } catch {
      throw .store(error)
    }
    guard let text = read else { return .skipped }
    let answer = try await ask(text, turn: turn, router: router)
    guard case .title(let title, let callIDs) = answer else {
      if case .refused(let hit, let callIDs) = answer {
        logger.notice("Left the chat untitled: the hard line refused its name rule=\(hit.rule.rawValue, privacy: .public)")
        return .refused(hit, callIDs: callIDs)
      }
      return .kept(callIDs: answer.callIDs)
    }
    let written: Bool
    do throws(StoreError) {
      written = try await store.write { transaction in try nameIfUntitled(session, novel: novel, title: title, in: &transaction) }
    } catch {
      throw .store(error)
    }
    return written ? .named(title, callIDs: callIDs) : .kept(callIDs: callIDs)
  }

  /// chat-session.service.ts:140-143 and chat.service.ts:331 (`ordinal === 1`): the trimmed text of `message` when it is the author's and the first message
  /// of the session's transcript, at least 15 UTF-16 units long, and the session holds neither the author's title nor an automatic one. A transcript this
  /// device cannot read names nothing.
  static func openingText(session: UUID, novel: UUID, message: UUID, in transaction: ReadTransaction) throws(StoreError) -> String? {
    guard let record = try untitled(session, novel: novel, in: transaction) else { return nil }
    guard case .readable(let entry) = try ChatMessageRecord.read(id: message, in: transaction), entry.record.session == record.id, entry.record.novel == novel,
      entry.record.role == .known(.user)
    else { return nil }
    let tables = ChatTranscript.tables
    let faults = try ChatReadFaults(novel: nil, subject: record.ref, reading: tables, in: transaction)
    let first = try faults.section(tables) { () throws(StoreError) -> String? in
      try transaction.query { database in
        try String.fetchOne(
          database, sql: "SELECT message FROM \(ChatTranscriptRow.databaseTableName) WHERE session = ? ORDER BY position LIMIT 1", arguments: [session])
      }
    }
    guard case .available(let key?) = first, key == ChatMessageRecord.ref(message).key.rawValue else { return nil }
    let text = entry.record.content.jsTrim()
    return text.jsLength >= minimumCharacters ? text : nil
  }

  /// Checked again where the name is written: a rename the author made while the model ran must never be covered (chat-session.service.ts:160).
  static func nameIfUntitled(_ session: UUID, novel: UUID, title: String, in transaction: inout WriteTransaction) throws(StoreError) -> Bool {
    guard try untitled(session, novel: novel, in: transaction) != nil else { return false }
    var edit = ChatSessionEdit()
    do throws(ChatRecordError) {
      try edit.nameAutomatically(title)
    } catch {
      return false
    }
    _ = try ChatSessionRecord.edit(id: session, edit, in: &transaction)
    return true
  }

  private static func untitled<Transaction: StateReading & ~Copyable>(_ session: UUID, novel: UUID, in transaction: borrowing Transaction) throws(StoreError)
    -> ChatSessionRecord?
  {
    let record: ChatSessionRecord
    do throws(ChatSessionError) {
      record = try ChatSessionOperations.live(session, novel: novel, in: transaction)
    } catch {
      if case .store(let cause) = error { throw cause }
      return nil
    }
    return record.title == nil && record.autoTitle == nil ? record : nil
  }

  private enum Answer {
    case title(String, callIDs: [UUID])
    case blank(callIDs: [UUID])
    case refused(HardLineHit, callIDs: [UUID])

    var callIDs: [UUID] {
      switch self {
      case .title(_, let callIDs), .blank(let callIDs), .refused(_, let callIDs): callIDs
      }
    }
  }

  /// chat-session.service.ts:148-158. An unrestricted turn's name is held to the hard line on its input and its output, as the reference's router holds
  /// every unrestricted call (model-router.service.ts:464, :763); the route's guard screens each request.
  private static func ask(_ message: String, turn: ChatAutoTitleTurn, router: TaskRouter) async throws(ChatAutoTitleError) -> Answer {
    let unrestricted = turn.contentMode == .unrestricted
    if unrestricted, let hit = screenTexts(inputScreens(OrderedJSONObject([(key: "message", value: .string(message))]))) { return .refused(hit, callIDs: []) }
    let call: RoutedCall
    do {
      call = try await router.prepare(TaskCall(task: task, pace: turn.pace, contentMode: unrestricted ? .unrestricted : .standard, consent: turn.consent))
    } catch {
      throw .routing(error)
    }
    let prompt = chatTitleMessages(message: message)
    let system = prompt.filter { $0.role == .system }.map { ContextSegment(text: $0.text) }
    let messages = prompt.filter { $0.role != .system }.map { ModelMessage(role: $0.role == .assistant ? .assistant : .user, text: $0.text) }
    let result: StructuredResult
    do throws(StructuredStreamFailure) {
      result = try await call.streamStructured(call.request(system: system, messages: messages), name: schemaName, schema: JSONValue(schema: chatTitleSchema))
    } catch {
      if let hit = error.error.hardLineHit { return .refused(hit, callIDs: error.callIDs) }
      throw .model(error.error, callIDs: error.callIDs)
    }
    let output: Output
    do {
      output = try result.decode()
    } catch {
      throw .model(error, callIDs: result.callIDs)
    }
    let title = output.title.jsTrim()
    if unrestricted, let hit = screenTexts(outputScreens(.object(OrderedJSONObject([(key: "title", value: .string(title))])), role: role)) {
      return .refused(hit, callIDs: result.callIDs)
    }
    return title.isEmpty ? .blank(callIDs: result.callIDs) : .title(title, callIDs: result.callIDs)
  }
}
