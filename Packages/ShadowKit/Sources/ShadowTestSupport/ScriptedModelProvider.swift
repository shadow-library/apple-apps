import ShadowAI
import Synchronization

public final class ScriptedModelProvider: ModelProvider {
  public enum Step: Sendable {
    case event(ModelEvent)
    /// Yields the text as deltas split before each run of whitespace.
    case text(String)
    case delay(Duration)
    case failure(ModelError)
  }

  private struct State {
    var calls: [[Step]]
    var validations: [Result<CredentialStatus, ModelError>]
    var modelLists: [Result<[RemoteModel], ModelError>]
    var requests: [ModelRequest] = []
    var validatedCredentials: [ProviderCredential] = []
    var modelsCallCount = 0
  }

  private let state: Mutex<State>
  private let clock: any Clock<Duration>

  public init(
    calls: [[Step]] = [],
    validations: [Result<CredentialStatus, ModelError>] = [],
    modelLists: [Result<[RemoteModel], ModelError>] = [],
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    state = Mutex(State(calls: calls, validations: validations, modelLists: modelLists))
    self.clock = clock
  }

  public var requests: [ModelRequest] { state.withLock { $0.requests } }

  public var validatedCredentials: [ProviderCredential] { state.withLock { $0.validatedCredentials } }

  public var modelsCallCount: Int { state.withLock { $0.modelsCallCount } }

  public var remainingCalls: Int { state.withLock { $0.calls.count } }

  public func enqueue(_ steps: [Step]) {
    state.withLock { $0.calls.append(steps) }
  }

  public func enqueueReply(
    _ text: String,
    usage: TokenUsage = TokenUsage(input: 10, output: 5),
    reportedCost: Cost? = nil,
    stop: StopReason = .endTurn,
    requestID: String? = "req_scripted",
    generationID: String? = nil
  ) {
    enqueue(Self.reply(text, usage: usage, reportedCost: reportedCost, stop: stop, requestID: requestID, generationID: generationID))
  }

  public func enqueueValidation(_ result: Result<CredentialStatus, ModelError>) {
    state.withLock { $0.validations.append(result) }
  }

  public func enqueueModels(_ result: Result<[RemoteModel], ModelError>) {
    state.withLock { $0.modelLists.append(result) }
  }

  public static func reply(
    _ text: String,
    usage: TokenUsage = TokenUsage(input: 10, output: 5),
    reportedCost: Cost? = nil,
    stop: StopReason = .endTurn,
    requestID: String? = "req_scripted",
    generationID: String? = nil
  ) -> [Step] {
    [.event(.started(requestID: requestID, generationID: generationID)), .text(text), .event(.finished(usage: usage, reportedCost: reportedCost, stop: stop))]
  }

  public static func deltas(of text: String) -> [String] {
    var deltas: [String] = []
    var current = ""
    var previousIsWhitespace = false
    for character in text {
      if character.isWhitespace, !previousIsWhitespace, !current.isEmpty {
        deltas.append(current)
        current = ""
      }
      current.append(character)
      previousIsWhitespace = character.isWhitespace
    }
    if !current.isEmpty { deltas.append(current) }
    return deltas
  }

  /// Records the request and takes the next scripted call when the stream is first iterated, as a real provider sends it.
  public func stream(_ request: ModelRequest) -> ModelStream {
    ModelStream { continuation throws(ModelError) in
      for step in try self.takeScript(for: request) {
        switch step {
        case .event(let event):
          try continuation.yield(event)
        case .text(let text):
          for delta in Self.deltas(of: text) { try continuation.yield(.textDelta(delta)) }
        case .delay(let duration):
          do {
            try await self.clock.sleep(for: duration)
          } catch {
            throw .cancelled
          }
        case .failure(let error):
          throw error
        }
      }
    }
  }

  private func takeScript(for request: ModelRequest) throws(ModelError) -> [Step] {
    let script: Result<[Step], ModelError> = state.withLock { state in
      state.requests.append(request)
      guard !state.calls.isEmpty else {
        return .failure(.invalidRequest("ScriptedModelProvider: stream call \(state.requests.count) has no script; \(state.requests.count - 1) were scripted."))
      }
      return .success(state.calls.removeFirst())
    }
    return try script.get()
  }

  public func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    let result: Result<CredentialStatus, ModelError> = state.withLock { state in
      state.validatedCredentials.append(credential)
      guard !state.validations.isEmpty else {
        return .failure(.invalidRequest("ScriptedModelProvider: validate call \(state.validatedCredentials.count) has no scripted result."))
      }
      return state.validations.removeFirst()
    }
    return try result.get()
  }

  public func models() async throws(ModelError) -> [RemoteModel] {
    let result: Result<[RemoteModel], ModelError> = state.withLock { state in
      state.modelsCallCount += 1
      guard !state.modelLists.isEmpty else {
        return .failure(.invalidRequest("ScriptedModelProvider: models call \(state.modelsCallCount) has no scripted result."))
      }
      return state.modelLists.removeFirst()
    }
    return try result.get()
  }
}
