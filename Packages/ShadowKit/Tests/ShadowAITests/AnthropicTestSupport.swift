import Foundation
import ShadowCore
import ShadowNetworking
import ShadowTestSupport
import Testing

@testable import ShadowAI

extension StubHTTPExchangeTransport {
  convenience init(status: Int = 200, headers: [String: String] = ["request-id": "req_1"], transcript: String) {
    self.init(status: status, headers: headers, steps: [.text(transcript)])
  }
}

struct AnthropicFrozenTime: MonotonicTimeSource {
  func nanoseconds() -> UInt64 { 0 }
}

enum AnthropicFixtures {
  static let request = ModelRequest(model: "claude-opus-5-5", system: [ContextSegment(text: "You write fiction.")], messages: [.user("Hi")], maxOutputTokens: 1_024)

  static let reply = #"""
    event: message_start
    data: {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

    event: content_block_start
    data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}

    event: content_block_stop
    data: {"type": "content_block_stop", "index": 0}

    event: message_delta
    data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": null}, "usage": {"output_tokens": 15}}

    event: message_stop
    data: {"type": "message_stop"}


    """#

  static let replyEvents: [ModelEvent] = [
    .started(requestID: "req_1", generationID: "msg_1"), .textDelta("Hello"), .finished(usage: TokenUsage(input: 25, output: 15), reportedCost: nil, stop: .endTurn),
  ]

  static func credential(_ origin: String = "https://api.anthropic.com", secret: String = "sk-ant-test") throws -> ProviderCredential {
    try makeCredential(origin, secret: secret)
  }

  static func provider(
    _ transport: StubHTTPExchangeTransport,
    configuration: AnthropicConfiguration = .init(),
    credential: ProviderCredential,
    credentialCalls: RunCounter = RunCounter(),
    trustedClock: TrustedClock? = nil
  ) -> AnthropicProvider {
    AnthropicProvider(
      configuration: configuration,
      credential: { () async throws(ModelError) -> ProviderCredential in
        credentialCalls.increment()
        return credential
      },
      transport: transport,
      trustedClock: trustedClock
    )
  }

  static func drain(_ stream: ModelStream) async -> (events: [ModelEvent], error: ModelError?) {
    var events: [ModelEvent] = []
    do throws(ModelError) {
      for try await event in stream { events.append(event) }
      return (events, nil)
    } catch {
      return (events, error)
    }
  }

  static func body(of request: URLRequest?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(request?.httpBody))
  }

  static func headerNames(of request: URLRequest?) -> Set<String> {
    Set((request?.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
  }
}
