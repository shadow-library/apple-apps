import Foundation
import ShadowCore
import ShadowNetworking
import ShadowTestSupport
import Testing

@testable import ShadowAI

extension StubHTTPExchangeTransport {
  convenience init(status: Int = 200, headers: [String: String] = [:], sse: String) {
    self.init(status: status, headers: headers, steps: [.text(sse)])
  }
}

enum OpenRouterFixtures {
  static let origin = "https://openrouter.ai"
  static let secret = "sk-or-v1-test"
  static let request = ModelRequest(model: "anthropic/claude-sonnet-5", system: [ContextSegment(text: "Be brief.")], messages: [.user("Hi")], maxOutputTokens: 256)

  static func provider(
    _ transport: StubHTTPExchangeTransport,
    origin: String = origin,
    configuration: OpenRouterConfiguration = .init(),
    trustedClock: TrustedClock? = nil
  ) throws -> OpenRouterProvider {
    let credential = try makeCredential(origin, secret: secret)
    return OpenRouterProvider(configuration: configuration, credential: { () async throws(ModelError) in credential }, transport: transport, trustedClock: trustedClock)
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

  static func sse(_ payloads: String...) -> String {
    payloads.map { $0.hasPrefix(":") ? "\($0)\n\n" : "data: \($0)\n\n" }.joined()
  }

  static func chunk(_ content: String?, finish: String? = nil, native: String? = nil, id: String = "gen-1", extra: String = "") -> String {
    let contentJSON = content.map { "\"\($0)\"" } ?? "null"
    let finishJSON = finish.map { "\"\($0)\"" } ?? "null"
    let nativeJSON = native.map { "\"\($0)\"" } ?? "null"
    return """
      {"id":"\(id)","object":"chat.completion.chunk","created":1767225600,"model":"anthropic/claude-sonnet-5","provider":"Anthropic",\
      "choices":[{"index":0,"delta":{"role":"assistant","content":\(contentJSON)},"finish_reason":\(finishJSON),"native_finish_reason":\(nativeJSON)}]\(extra)}
      """
  }

  static func usageChunk(_ usage: String, finish: String = "stop", id: String = "gen-1") -> String {
    chunk("", finish: finish, id: id, extra: ",\"usage\":\(usage)")
  }

  static func errorChunk(code: Int, message: String, type: String, id: String = "gen-1") -> String {
    """
    {"id":"\(id)","object":"chat.completion.chunk","created":1767225600,"model":"anthropic/claude-sonnet-5","provider":"Anthropic",\
    "error":{"code":\(code),"message":"\(message)","metadata":{"error_type":"\(type)"}},\
    "choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}
    """
  }

  static func errorBody(code: Int, message: String, metadata: String? = nil) -> String {
    let metadataJSON = metadata.map { ",\"metadata\":\($0)" } ?? ""
    return "{\"error\":{\"code\":\(code),\"message\":\"\(message)\"\(metadataJSON)}}"
  }

  static func json(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
  }

  static func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
