import Foundation
import ShadowCore

struct AnthropicRequestBody: Encodable {
  struct CacheControl: Encodable {
    let type = "ephemeral"
  }

  struct SystemBlock: Encodable {
    let type = "text"
    let text: String
    let cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
      case type
      case text
      case cacheControl = "cache_control"
    }
  }

  struct Message: Encodable {
    let role: String
    let content: String
  }

  struct Format: Encodable {
    let type = "json_schema"
    let schema: JSONValue
  }

  struct OutputConfig: Encodable {
    let effort: String?
    let format: Format?
  }

  let model: String
  let maxTokens: Int
  let stream = true
  let system: [SystemBlock]?
  let messages: [Message]
  let outputConfig: OutputConfig?
  let cacheControl: CacheControl?

  enum CodingKeys: String, CodingKey {
    case model
    case maxTokens = "max_tokens"
    case stream
    case system
    case messages
    case outputConfig = "output_config"
    case cacheControl = "cache_control"
  }

  init(_ request: ModelRequest) {
    model = request.model
    maxTokens = request.maxOutputTokens
    system = request.system.isEmpty ? nil : request.system.map { SystemBlock(text: $0.text, cacheControl: $0.endsStablePrefix ? CacheControl() : nil) }
    messages = request.messages.map { Message(role: $0.role.rawValue, content: $0.text) }
    let format: Format? =
      switch request.format {
      case .text: nil
      case .json(_, let schema): Format(schema: schema)
      }
    outputConfig = request.effort == nil && format == nil ? nil : OutputConfig(effort: request.effort?.rawValue, format: format)
    cacheControl = request.cachesConversation ? CacheControl() : nil
  }

  func encoded() throws(ModelError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(self)
    } catch {
      throw .invalidRequest("The request could not be encoded.")
    }
  }
}
