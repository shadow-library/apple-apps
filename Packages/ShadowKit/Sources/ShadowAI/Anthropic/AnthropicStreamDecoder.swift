import Foundation
import ShadowNetworking

struct AnthropicStreamDecoder {
  private struct Envelope: Decodable {
    let type: String
  }

  private struct Usage: Decodable {
    struct CacheCreation: Decodable {
      let shortLived: Int?
      let longLived: Int?

      enum CodingKeys: String, CodingKey {
        case shortLived = "ephemeral_5m_input_tokens"
        case longLived = "ephemeral_1h_input_tokens"
      }
    }

    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let cacheCreation: CacheCreation?

    enum CodingKeys: String, CodingKey {
      case input = "input_tokens"
      case output = "output_tokens"
      case cacheRead = "cache_read_input_tokens"
      case cacheWrite = "cache_creation_input_tokens"
      case cacheCreation = "cache_creation"
    }
  }

  private struct MessageStart: Decodable {
    struct Message: Decodable {
      let id: String?
      let usage: Usage?
    }

    let message: Message
  }

  private struct ContentBlockStart: Decodable {
    struct Block: Decodable {
      let type: String
      let text: String?
    }

    let block: Block

    enum CodingKeys: String, CodingKey {
      case block = "content_block"
    }
  }

  private struct ContentBlockDelta: Decodable {
    struct Delta: Decodable {
      let type: String
      let text: String?
    }

    let delta: Delta
  }

  private struct MessageDelta: Decodable {
    struct Delta: Decodable {
      struct StopDetails: Decodable {
        let category: String?
      }

      let stopReason: String?
      let stopDetails: StopDetails?

      enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
      }
    }

    let delta: Delta
    let usage: Usage?
  }

  private struct ErrorEvent: Decodable {
    let error: AnthropicErrors.Detail
  }

  private enum Phase {
    case awaitingStart
    case streaming
    case complete
  }

  private let requestID: String?
  private var phase = Phase.awaitingStart
  private var deliveredText = false
  private var stopReason: String?
  private var refusalCategory: String?
  private var input = 0
  private var output = 0
  private var cacheRead = 0
  private var cacheWrite: Int?
  private var cacheWriteShort = 0
  private var cacheWriteLong = 0

  init(requestID: String?) {
    self.requestID = requestID
  }

  var isComplete: Bool { phase == .complete }

  mutating func consume(_ event: ServerSentEvent) throws(ModelError) -> [ModelEvent] {
    guard phase != .complete else { return [] }
    let data = Data(event.data.utf8)
    let name: String
    if let named = event.event {
      name = named
    } else {
      name = try Self.decode(Envelope.self, from: data, event: "unnamed").type
    }
    switch name {
    case "message_start":
      return try start(Self.decode(MessageStart.self, from: data, event: "message_start"))
    case "content_block_start":
      let block = try Self.decode(ContentBlockStart.self, from: data, event: "content_block_start").block
      try requireStarted()
      guard block.type == "text" else { return [] }
      return text(block.text)
    case "content_block_delta":
      let delta = try Self.decode(ContentBlockDelta.self, from: data, event: "content_block_delta").delta
      try requireStarted()
      guard delta.type == "text_delta" else { return [] }
      guard let text = delta.text else { throw .malformedResponse("The provider sent a text delta without text.") }
      return self.text(text)
    case "content_block_stop":
      try requireStarted()
      return []
    case "message_delta":
      let delta = try Self.decode(MessageDelta.self, from: data, event: "message_delta")
      try requireStarted()
      if let reason = delta.delta.stopReason {
        stopReason = reason
        refusalCategory = delta.delta.stopDetails?.category
      }
      if let usage = delta.usage { merge(usage) }
      return []
    case "message_stop":
      try requireStarted()
      guard let stopReason else { throw .malformedResponse("The reply finished without a stop reason.") }
      phase = .complete
      return [.finished(usage: usage, reportedCost: nil, stop: Self.stop(stopReason, category: refusalCategory))]
    case "error":
      throw AnthropicErrors.inStream(try Self.decode(ErrorEvent.self, from: data, event: "error").error, afterText: deliveredText)
    default:
      return []
    }
  }

  private mutating func start(_ start: MessageStart) throws(ModelError) -> [ModelEvent] {
    guard phase == .awaitingStart else { throw .malformedResponse("The provider started the reply twice.") }
    phase = .streaming
    if let usage = start.message.usage { merge(usage) }
    return [.started(requestID: requestID, generationID: start.message.id)]
  }

  private mutating func text(_ text: String?) -> [ModelEvent] {
    guard let text, !text.isEmpty else { return [] }
    deliveredText = true
    return [.textDelta(text)]
  }

  private func requireStarted() throws(ModelError) {
    guard phase == .streaming else { throw .malformedResponse("The provider sent content before starting the reply.") }
  }

  private mutating func merge(_ usage: Usage) {
    if let value = usage.input { input = max(value, 0) }
    if let value = usage.output { output = max(value, 0) }
    if let value = usage.cacheRead { cacheRead = max(value, 0) }
    if let value = usage.cacheWrite { cacheWrite = max(value, 0) }
    if let breakdown = usage.cacheCreation {
      cacheWriteShort = max(breakdown.shortLived ?? 0, 0)
      cacheWriteLong = max(breakdown.longLived ?? 0, 0)
    }
  }

  /// Relies on the adapter only ever requesting the default 5-minute lifetime, since deltas carry only the cumulative cache-write total.
  private var usage: TokenUsage {
    let short = cacheWrite.map { max($0 - cacheWriteLong, 0) } ?? cacheWriteShort
    return TokenUsage(input: input, output: output, cacheRead: cacheRead, cacheWriteShort: short, cacheWriteLong: cacheWriteLong)
  }

  private static func stop(_ reason: String, category: String?) -> StopReason {
    switch reason {
    case "end_turn": .endTurn
    case "max_tokens", "model_context_window_exceeded": .maxTokens
    case "refusal": .refusal(category: category)
    default: .other(reason)
    }
  }

  private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data, event: String) throws(ModelError) -> Payload {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw .malformedResponse("The provider sent an unreadable \(event) event.")
    }
  }
}
