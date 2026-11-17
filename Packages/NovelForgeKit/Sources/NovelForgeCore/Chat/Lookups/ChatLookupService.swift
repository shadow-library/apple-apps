import Foundation
import ShadowStore

struct ChatLookupCall: Equatable, Sendable {
  let tool: String
  let args: OrderedJSONObject?
}

enum ChatLookupAudit: String, Sendable, Equatable {
  case ok
  case budgetExceeded = "budget_exceeded"
  case handlerError = "handler_error"
  case invalidArgs = "invalid_args"

  var status: ChatTraceStatus { self == .ok ? .ok : .error }
}

/// What a turn records of one lookup: which, with which arguments, and how it settled; never the result itself.
struct ChatLookupTrace: Equatable, Sendable {
  let tool: String
  let args: ChatTraceArgs
  let status: ChatTraceStatus
  let audit: ChatLookupAudit
  let resultCharacters: Int
  let truncated: Bool
}

struct ChatLookupOutcome: Equatable, Sendable {
  let result: String
  let trace: ChatLookupTrace
  let readsPlannerOnly: Bool
}

struct ChatLookupRound: Equatable, Sendable {
  let outcomes: [ChatLookupOutcome]

  // chat-lookup.service.ts:117
  var text: String { outcomes.map { "### \($0.trace.tool)\n\($0.result)" }.joined(separator: "\n\n") }
  var readsPlannerOnly: Bool { outcomes.contains(where: \.readsPlannerOnly) }
}

/// Calls made per tool across a turn's rounds, so `maxCallsPerRun` holds for the turn.
struct ChatLookupCounts: Equatable, Sendable {
  private var counts: [JSString: Int] = [:]

  mutating func record(_ tool: String) -> Int {
    counts[JSString(tool), default: 0] += 1
    return counts[JSString(tool)] ?? 0
  }
}

private enum Planned {
  case refused(String, ChatLookupAudit)
  case request(ChatLookupDefinition, ChatLookupRequest)
}

private let truncationNotice = "\n...[truncated]"
private let lookupFailed = "error: lookup failed"

/// Runs the lookups the model asked for, answering from the vault; a refusal or a failure is text for the model, never an error thrown into the turn.
struct ChatLookupService: Sendable {
  let store: VaultStore
  let novel: UUID
  let now: @Sendable () -> Date

  init(store: VaultStore, novel: UUID, now: @escaping @Sendable () -> Date = { Date() }) {
    self.store = store
    self.novel = novel
    self.now = now
  }

  // chat-lookup.service.ts:51
  func execute(_ calls: [ChatLookupCall], counts: inout ChatLookupCounts) async -> ChatLookupRound {
    let plans = calls.map { plan($0, counts: &counts) }
    let answers = await answers(for: plans)
    return ChatLookupRound(outcomes: zip(calls, zip(plans, answers)).map { settle($0, $1.0, $1.1) })
  }

  private func plan(_ call: ChatLookupCall, counts: inout ChatLookupCounts) -> Planned {
    let count = counts.record(call.tool)
    guard let definition = ChatLookups.definition(named: call.tool) else { return .refused("error: unknown tool '\(call.tool)'", .invalidArgs) }
    guard count <= definition.maxCallsPerRun else { return .refused("error: tool '\(call.tool)' has exceeded its call budget for this turn", .budgetExceeded) }
    do {
      return .request(definition, try definition.name.parse(call.args ?? OrderedJSONObject([])))
    } catch {
      return .refused(error.text, .invalidArgs)
    }
  }

  private func answers(for plans: [Planned]) async -> [Result<String, ChatLookupFailure>?] {
    let requests = plans.map { plan -> ChatLookupRequest? in
      guard case .request(_, let request) = plan else { return nil }
      return request
    }
    guard requests.contains(where: { $0 != nil }) else { return requests.map { _ in nil } }
    let (novel, now) = (novel, now())
    do {
      return try await store.read { transaction in
        let reader = ChatLookupReader(transaction: transaction, novel: novel, now: now)
        return requests.map { request in request.map { reader.answer($0) } }
      }
    } catch {
      return requests.map { $0.map { _ in .failure(ChatLookupFailure()) } }
    }
  }

  private func settle(_ call: ChatLookupCall, _ plan: Planned, _ answer: Result<String, ChatLookupFailure>?) -> ChatLookupOutcome {
    let trace = traceArgs(tool: call.tool, args: call.args ?? OrderedJSONObject([]))
    switch (plan, answer) {
    case (.refused(let text, let audit), _): return outcome(call, trace, text, audit)
    case (.request(let definition, let request), .success(let text)?):
      let truncated = text.jsLength > definition.characterLimit
      let result = truncated ? text.jsSlice(0, definition.characterLimit) + truncationNotice : text
      return outcome(call, trace, result, .ok, truncated: truncated, readsPlannerOnly: readsPlannerOnlyPage(tool: call.tool, args: request.plannerGuardArguments))
    default: return outcome(call, trace, lookupFailed, .handlerError)
    }
  }

  private func outcome(_ call: ChatLookupCall, _ args: ChatTraceArgs, _ result: String, _ audit: ChatLookupAudit, truncated: Bool = false, readsPlannerOnly: Bool = false)
    -> ChatLookupOutcome
  {
    let trace = ChatLookupTrace(tool: call.tool, args: args, status: audit.status, audit: audit, resultCharacters: result.jsLength, truncated: truncated)
    return ChatLookupOutcome(result: result, trace: trace, readsPlannerOnly: readsPlannerOnly)
  }
}

extension ChatLookupReader {
  func answer(_ request: ChatLookupRequest) -> Result<String, ChatLookupFailure> {
    do throws(ChatLookupFailure) {
      switch request {
      case .bibleDocument(let section, let slug): return .success(try bibleDocument(section: section, slug: slug))
      case .brief(let chapter): return .success(try brief(chapter: chapter))
      case .draft(let chapter): return .success(try draft(chapter: chapter))
      case .entity(let key): return .success(try entity(key: key))
      case .canonFacts(let keys): return .success(try canonFacts(keys: keys))
      case .chapterSummaries(let from, let to): return .success(try chapterSummaries(from: from, to: to))
      case .plotThreads(let status): return .success(try plotThreads(status: status))
      case .volume(let key): return .success(try volume(key: key))
      case .notes(let from, let part, let query): return .success(try notes(from: from, part: part, query: query))
      case .usage(let chapter, let period, let lastRun): return .success(try usage(chapter: chapter, period: period, lastRun: lastRun))
      }
    } catch {
      return .failure(error)
    }
  }
}
