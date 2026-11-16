import Foundation

struct OpenRouterStreamState {
  private static let sentinel = "[DONE]"
  private static let maxIdentifierLength = 256

  private let secret: String?
  private(set) var generationID: String?
  private(set) var hasStarted = false
  private(set) var hasDeliveredText = false
  private(set) var isDone = false
  private var finishReason: String?
  private var nativeFinishReason: String?
  private var sawRefusal = false
  private var usage: OpenRouterUsage?

  init(secret: String?) {
    self.secret = secret
  }

  // OpenRouter documents `X-Generation-Id` on every endpoint's response, so the id is known before the first chunk's `id` arrives.
  mutating func start(generationHeader: String?) -> ModelEvent? {
    guard let id = Self.identifier(generationHeader) else { return nil }
    generationID = id
    hasStarted = true
    return .started(requestID: nil, generationID: id)
  }

  mutating func ingest(_ data: String, emit: (ModelEvent) throws(ModelError) -> Void) throws(ModelError) {
    guard !isDone else { return }
    if data.trimmingCharacters(in: .whitespaces) == Self.sentinel {
      isDone = true
      return
    }
    let chunk: OpenRouterChunk
    do {
      chunk = try JSONDecoder().decode(OpenRouterChunk.self, from: Data(data.utf8))
    } catch {
      throw .malformedResponse("The provider sent a stream chunk that is not a chat-completion chunk.")
    }
    if !hasStarted {
      hasStarted = true
      generationID = Self.identifier(chunk.id)
      try emit(.started(requestID: nil, generationID: generationID))
    }
    if let usage = chunk.usage { self.usage = usage }
    let choice = chunk.choices.first
    if let error = chunk.error ?? choice?.error ?? (choice?.finishReason == "error" ? OpenRouterErrorBody() : nil) {
      throw OpenRouterFailure.error(error, status: nil, retryAfter: nil, afterText: hasDeliveredText, secret: secret)
    }
    guard let choice else { return }
    guard finishReason == nil else { return }
    if let refusal = choice.delta?.refusal, !refusal.isEmpty { sawRefusal = true }
    if let content = choice.delta?.content, !content.isEmpty {
      hasDeliveredText = true
      try emit(.textDelta(content))
    }
    if let reason = choice.finishReason {
      finishReason = reason
      nativeFinishReason = choice.nativeFinishReason
    }
  }

  func finished() throws(ModelError) -> ModelEvent {
    guard isDone || finishReason != nil else { throw .malformedResponse("The reply ended before it finished.") }
    return .finished(usage: usage?.tokenUsage ?? .zero, reportedCost: usage?.cost?.nanoUSD, stop: stopReason)
  }

  private var stopReason: StopReason {
    switch finishReason {
    case "stop": .endTurn
    case "length": .maxTokens
    case "content_filter": sawRefusal || nativeFinishReason == "refusal" ? .refusal(category: nil) : .contentFilter
    case let reason?: .other(reason)
    case nil: .other("none")
    }
  }

  private static func identifier(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.count <= maxIdentifierLength else { return nil }
    guard value.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
    return value
  }
}
