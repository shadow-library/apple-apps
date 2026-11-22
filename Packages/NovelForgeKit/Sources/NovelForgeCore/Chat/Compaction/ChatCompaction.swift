import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowText

/// The turn a compaction runs before: its content mode and the novel's raise the fold, its pace routes it; without unrestricted writing a fold that
/// would be unrestricted is refused rather than sent.
struct ChatCompactionTurn: Equatable, Sendable {
  let contentMode: ContentMode
  let novelMode: ContentMode
  let pace: Pace
  let consent: AIConsentRequirement
  let unrestrictedAvailable: Bool
}

enum ChatFoldOutcome: Equatable, Sendable {
  case kept
  case folded(summary: UUID, mode: ContentMode, callIDs: [UUID])
  /// Nothing was written; the turn runs on the unfolded window and the next turn tries again (chat-compaction.service.ts:154-165).
  case refused(HardLineHit, callIDs: [UUID])
}

struct ChatCompactionResult: Equatable, Sendable {
  let outcome: ChatFoldOutcome
  /// The window as it stands after the fold, which may already hold a summary another device wrote.
  let window: ChatConversationWindow
}

enum ChatCompactionError: ShadowError {
  case windowUnavailable([ReadFault])
  case store(StoreError)
  case routing(TaskRouterError)
  /// `callIDs` are the ledger ids of the requests the failed fold made, so their spend can be attributed.
  case model(StructuredError, callIDs: [UUID])
  case record(ChatRecordError)
  /// The fold would be unrestricted, which this build cannot write; nothing was sent.
  case unrestrictedUnavailable

  var code: String {
    switch self {
    case .windowUnavailable: "chat_compaction.window_unavailable"
    case .store: "chat_compaction.store"
    case .routing(let error): error.code
    case .model(let error, _): error.code
    case .record(let error): error.code
    case .unrestrictedUnavailable: "AI_024"
    }
  }

  var errorDescription: String? {
    switch self {
    case .windowUnavailable: "This conversation could not be read on this device just now."
    case .store(let error): error.errorDescription
    case .routing(let error): error.errorDescription
    case .model(let error, _): error.errorDescription
    case .record(let error): error.errorDescription
    case .unrestrictedUnavailable: "Unrestricted writing isn't available in this version."
    }
  }
}

enum ChatCompaction {
  private static let logger = Logger(category: "chat.compaction")
  // apps/novel-forge-server/src/modules/ai/defaults.ts:56
  private static let task = ModelTask.helper
  private static let role = "compact"

  private struct Snapshot: Sendable {
    let window: ChatConversationWindow
    let holdsStaleExchanges: Bool
  }

  private enum Summarised {
    case summary(String, callIDs: [UUID])
    case refused(HardLineHit, callIDs: [UUID])
  }

  private struct Output: Decodable {
    let summary: String
  }

  /// Runs before every turn and returns the window the turn sends. A fold appends a summary covering every message the standing one covers plus the folded
  /// ones, and ends the session's exchange segments in the same transaction; two devices folding at once both append and the read side keeps the one
  /// covering most. The exchange log is also forgotten when the window's watermark moved without a fold here, as when a summary arrives by sync.
  // apps/novel-forge-server/src/modules/refinement/chat-compaction.service.ts:118-178
  @concurrent
  static func compactIfNeeded(session: UUID, turn: ChatCompactionTurn, store: VaultStore, router: TaskRouter) async throws(ChatCompactionError)
    -> ChatCompactionResult
  {
    let before = try await snapshot(session, in: store)
    guard let plan = before.window.foldPlan() else { return try await kept(before, outcome: .kept, in: store) }
    let mode = before.window.foldMode(plan, turn: turn.contentMode, novel: turn.novelMode)
    guard mode == .standard || turn.unrestrictedAvailable else { throw .unrestrictedUnavailable }
    switch try await summarise(plan, mode: mode, turn: turn, router: router) {
    case .refused(let hit, let callIDs):
      logger.notice(
        "Kept the verbatim window: the hard line refused the fold rule=\(hit.rule.rawValue, privacy: .public) source=\(hit.source, privacy: .public)")
      return try await kept(before, outcome: .refused(hit, callIDs: callIDs), in: store)
    case .summary(let text, let callIDs):
      let summary: ChatSummaryRecord
      do {
        summary = try ChatSummaryRecord(novel: plan.novel, session: session, covered: plan.covered, text: text, contentMode: mode)
      } catch {
        throw .record(error)
      }
      do {
        try await store.write { transaction in
          _ = try summary.append(in: &transaction)
          try ChatContextExchangeLog.forget(session: session, in: transaction.database)
        }
      } catch {
        throw .store(error)
      }
      let after = try await snapshot(session, in: store)
      return ChatCompactionResult(outcome: .folded(summary: summary.id, mode: mode, callIDs: callIDs), window: after.window)
    }
  }

  private static func kept(_ snapshot: Snapshot, outcome: ChatFoldOutcome, in store: VaultStore) async throws(ChatCompactionError) -> ChatCompactionResult {
    if snapshot.holdsStaleExchanges {
      let session = snapshot.window.session
      do {
        try await store.write { transaction in try ChatContextExchangeLog.forget(session: session, in: transaction.database) }
      } catch {
        throw .store(error)
      }
    }
    return ChatCompactionResult(outcome: outcome, window: snapshot.window)
  }

  private static func snapshot(_ session: UUID, in store: VaultStore) async throws(ChatCompactionError) -> Snapshot {
    let read: Result<Snapshot, ChatCompactionError>
    do throws(StoreError) {
      read = try await store.read { transaction in
        Result { () throws(ChatCompactionError) -> Snapshot in
          let window = try ChatConversationWindow.load(session, in: transaction)
          let exchanges: [UUID: ChatExchange]
          do throws(StoreError) {
            exchanges = try ChatContextExchangeLog.load(session: session, in: transaction.database)
          } catch {
            throw .store(error)
          }
          let stale = exchanges.values.contains { exchange in exchange.opening.map { !$0.through.jsEquals(window.watermark) } ?? false }
          return Snapshot(window: window, holdsStaleExchanges: stale)
        }
      }
    } catch {
      throw .store(error)
    }
    return try read.get()
  }

  /// An unrestricted fold is held to the hard line on its inputs and its output, as the reference's router holds every unrestricted call
  /// (model-router.service.ts:464, :763); a standard one is not screened (:721-726). The router's request guard (:710-719) screens every request the
  /// fold sends, its repair re-ask included, and sends the hard line's system line first.
  // chat-compaction.service.ts:145-153
  private static func summarise(_ plan: ChatFoldPlan, mode: ContentMode, turn: ChatCompactionTurn, router: TaskRouter) async throws(ChatCompactionError)
    -> Summarised
  {
    let prompt = chatCompactMessages(priorSummary: plan.priorSummary, transcript: plan.transcript)
    let unrestricted = mode == .unrestricted
    if unrestricted, let hit = screenTexts(inputScreens(plan.input)) { return .refused(hit, callIDs: []) }
    let call: RoutedCall
    do {
      call = try await router.prepare(TaskCall(task: task, pace: turn.pace, contentMode: unrestricted ? .unrestricted : .standard, consent: turn.consent))
    } catch {
      throw .routing(error)
    }
    let system = prompt.filter { $0.role == .system }.map(\.text)
    let messages = prompt.filter { $0.role != .system }.map { ModelMessage(role: $0.role == .assistant ? .assistant : .user, text: $0.text) }
    let result: StructuredResult
    do throws(StructuredStreamFailure) {
      result = try await call.streamStructured(
        call.request(system: system.map { ContextSegment(text: $0) }, messages: messages), name: chatCompactSchemaName, schema: JSONValue(schema: chatCompactSchema))
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
    if unrestricted, let hit = screenTexts(outputScreens(.object(OrderedJSONObject([(key: "summary", value: .string(output.summary))])), role: role)) {
      return .refused(hit, callIDs: result.callIDs)
    }
    return .summary(output.summary, callIDs: result.callIDs)
  }
}
