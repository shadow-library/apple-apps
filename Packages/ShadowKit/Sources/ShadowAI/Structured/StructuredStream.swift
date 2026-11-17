import Foundation
import OSLog
import ShadowCore

public enum StructuredAttemptPurpose: Sendable, Equatable {
  case answer
  case repair(issues: [JSONSchemaIssue])
}

public struct StructuredAttempt: Sendable, Equatable {
  /// Counts every request of the call from 1, a native request that fell back to the prompt form included.
  public let number: Int
  public let mode: StructuredMode
  public let purpose: StructuredAttemptPurpose
  /// Exactly what is sent to the provider.
  public let request: ModelRequest

  public init(number: Int, mode: StructuredMode, purpose: StructuredAttemptPurpose, request: ModelRequest) {
    self.number = number
    self.mode = mode
    self.purpose = purpose
    self.request = request
  }
}

/// What a streamed structured call shows while it runs. The text is advisory: the outcome, not the text shown, is the answer.
public enum StructuredStreamEvent: Sendable, Equatable {
  case attemptStarted(StructuredAttempt)
  /// Never empty.
  case textDelta(String)
  /// Everything shown so far is void: a repair replaces it, or the accepted answer is an earlier attempt's. A later value within the shown attempt
  /// emits none, so a consumer settles against `result.json`.
  case reset
  /// Always the last event, sent once.
  case completed(StructuredOutcome)
}

public enum StructuredOutcome: Sendable, Equatable {
  case succeeded(StructuredResult)
  case failed(StructuredStreamFailure)
}

public struct StructuredStreamFailure: ShadowError, Equatable {
  public let error: StructuredError
  /// What the attempt that broke off had streamed; empty when every attempt replied, since the replies are in the error's responses.
  public let partialText: String
  /// The ledger ids of the call's requests, through a `RoutedCall`; empty otherwise.
  public let callIDs: [UUID]

  public init(error: StructuredError, partialText: String, callIDs: [UUID]) {
    self.error = error
    self.partialText = partialText
    self.callIDs = callIDs
  }

  public var code: String { error.code }

  public var errorDescription: String? { error.errorDescription }
}

/// One structured call's requests, in order, and what the observer has been shown of them.
struct StructuredAttempts {
  private static let logger = Logger(category: "ShadowAI.Structured")

  private let provider: any ModelProvider
  private let requestGuard: ModelRequestGuard?
  private(set) var responses: [ModelResponse] = []
  private(set) var partialText = ""
  private(set) var count = 0
  private var shown: Int?

  init(provider: any ModelProvider, requestGuard: ModelRequestGuard?) {
    self.provider = provider
    self.requestGuard = requestGuard
  }

  /// Mirrors `ModelStream.collect()`, keeping the text of a reply that breaks off. A refused request is not an attempt: it is neither counted nor shown, and
  /// fails the call with `.model(.requestRefused)`.
  mutating func make(
    _ request: ModelRequest, mode: StructuredMode, purpose: StructuredAttemptPurpose, observer: (StructuredStreamEvent) -> Void
  ) async throws(StructuredError) -> ModelResponse {
    guard !Task.isCancelled else { throw .model(.cancelled, responses: responses) }
    if let requestGuard, case .refuse(let reason) = requestGuard.screen(request) {
      let number = count + 1
      Self.logger.notice("The request guard refused a request before it was sent attempt=\(number, privacy: .public) code=\(reason.code, privacy: .public)")
      throw .model(.requestRefused(ModelRequestRefusal(reason)), responses: responses)
    }
    let request = requestGuard?.framing(request) ?? request
    count += 1
    partialText = ""
    observer(.attemptStarted(StructuredAttempt(number: count, mode: mode, purpose: purpose, request: request)))
    if shown != nil {
      shown = nil
      observer(.reset)
    }
    var requestID: String?
    var generationID: String?
    var outcome: (usage: TokenUsage, reportedCost: Cost?, stop: StopReason)?
    do throws(ModelError) {
      for try await event in provider.stream(request) {
        guard outcome == nil else { throw .malformedResponse("The provider sent more after the reply finished.") }
        switch event {
        case .started(let request, let generation):
          requestID = request
          generationID = generation
        case .textDelta(let delta) where !delta.isEmpty:
          partialText += delta
          shown = count
          observer(.textDelta(delta))
        case .textDelta, .retrying:
          continue
        case .finished(let usage, let reportedCost, let stop):
          outcome = (usage, reportedCost, stop)
        }
      }
    } catch {
      throw .model(error, responses: responses)
    }
    guard let outcome else { throw .model(.malformedResponse("The reply ended before it finished."), responses: responses) }
    let response = ModelResponse(
      text: partialText, usage: outcome.usage, reportedCost: outcome.reportedCost, stop: outcome.stop, requestID: requestID, generationID: generationID)
    responses.append(response)
    partialText = ""
    return response
  }

  mutating func accept(attempt: Int, observer: (StructuredStreamEvent) -> Void) {
    guard let shown, shown != attempt else { return }
    self.shown = nil
    observer(.reset)
  }
}
