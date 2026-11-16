struct AnthropicModelPage: Decodable {
  struct Model: Decodable {
    struct Capabilities: Decodable {
      struct Support: Decodable {
        let supported: Bool?
      }

      let structuredOutputs: Support?

      enum CodingKeys: String, CodingKey {
        case structuredOutputs = "structured_outputs"
      }
    }

    let id: String
    let displayName: String?
    let maxInputTokens: Int?
    let maxTokens: Int?
    let capabilities: Capabilities?

    enum CodingKeys: String, CodingKey {
      case id
      case displayName = "display_name"
      case maxInputTokens = "max_input_tokens"
      case maxTokens = "max_tokens"
      case capabilities
    }

    var remote: RemoteModel {
      RemoteModel(id: id, name: displayName, contextLength: maxInputTokens, maxOutputTokens: maxTokens, supportsJSONSchema: capabilities?.structuredOutputs?.supported)
    }
  }

  let data: [Model]
  let hasMore: Bool
  let lastID: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case lastID = "last_id"
  }
}
