import ShadowCore

struct OpenRouterRequestBody: Encodable, Sendable {
  struct Message: Encodable, Sendable, Equatable {
    let role: String
    let content: Content
  }

  enum Content: Encodable, Sendable, Equatable {
    case text(String)
    case parts([Part])

    func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .text(let text): try container.encode(text)
      case .parts(let parts): try container.encode(parts)
      }
    }
  }

  struct Part: Encodable, Sendable, Equatable {
    let type = "text"
    let text: String
    let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
      case type
      case text
      case cacheControl = "cache_control"
    }
  }

  struct CacheControl: Encodable, Sendable, Equatable {
    let type = "ephemeral"
  }

  struct Reasoning: Encodable, Sendable {
    let effort: String
    let exclude = true
  }

  struct Provider: Encodable, Sendable {
    let requireParameters = true

    enum CodingKeys: String, CodingKey {
      case requireParameters = "require_parameters"
    }
  }

  struct ResponseFormat: Encodable, Sendable {
    struct Schema: Encodable, Sendable {
      let name: String
      let strict = true
      let schema: JSONValue
    }

    let type = "json_schema"
    let jsonSchema: Schema

    enum CodingKeys: String, CodingKey {
      case type
      case jsonSchema = "json_schema"
    }
  }

  let model: String
  let messages: [Message]
  let stream = true
  let maxCompletionTokens: Int
  let reasoning: Reasoning?
  let responseFormat: ResponseFormat?
  let provider: Provider?

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case maxCompletionTokens = "max_completion_tokens"
    case reasoning
    case responseFormat = "response_format"
    case provider
  }

  init(_ request: ModelRequest) {
    model = request.model
    messages = Self.messages(for: request)
    maxCompletionTokens = request.maxOutputTokens
    reasoning = request.effort.map { Reasoning(effort: $0.rawValue) }
    switch request.format {
    case .text:
      responseFormat = nil
      provider = nil
    case .json(let name, let schema):
      responseFormat = ResponseFormat(jsonSchema: .init(name: name, schema: schema))
      provider = Provider()
    }
  }

  private static func messages(for request: ModelRequest) -> [Message] {
    var messages: [Message] = []
    if let system = systemMessage(request.system) { messages.append(system) }
    let breakpoint = request.cachesConversation && request.messages.count >= 2 ? request.messages.count - 2 : nil
    for (index, message) in request.messages.enumerated() {
      let content: Content = index == breakpoint ? .parts([Part(text: message.text, cacheControl: CacheControl())]) : .text(message.text)
      messages.append(Message(role: message.role.rawValue, content: content))
    }
    return messages
  }

  private static func systemMessage(_ segments: [ContextSegment]) -> Message? {
    guard !segments.isEmpty else { return nil }
    if segments.count == 1, let only = segments.first, !only.endsStablePrefix { return Message(role: "system", content: .text(only.text)) }
    let parts = segments.map { Part(text: $0.text, cacheControl: $0.endsStablePrefix ? CacheControl() : nil) }
    return Message(role: "system", content: .parts(parts))
  }
}
