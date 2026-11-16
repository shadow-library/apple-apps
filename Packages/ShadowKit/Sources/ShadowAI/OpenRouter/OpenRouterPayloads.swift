import Foundation

struct OpenRouterErrorEnvelope: Decodable, Sendable {
  let error: OpenRouterErrorBody?

  enum CodingKeys: String, CodingKey {
    case error
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    error = try OpenRouterErrorBody.lenient(in: container, forKey: .error)
  }
}

struct OpenRouterErrorBody: Decodable, Sendable, Equatable {
  struct Metadata: Decodable, Sendable, Equatable {
    var errorType: String?
    var limitSource: String?
    var providerName: String?
    var rawMessage: String?

    enum CodingKeys: String, CodingKey {
      case errorType = "error_type"
      case limitSource = "limit_source"
      case providerName = "provider_name"
      case raw
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      errorType = try? container.decodeIfPresent(String.self, forKey: .errorType)
      limitSource = try? container.decodeIfPresent(String.self, forKey: .limitSource)
      providerName = try? container.decodeIfPresent(String.self, forKey: .providerName)
      if let raw = try? container.decodeIfPresent(String.self, forKey: .raw) {
        rawMessage = (try? JSONDecoder().decode(OpenRouterErrorEnvelope.self, from: Data(raw.utf8)))?.error?.message
      } else {
        rawMessage = (try? container.decodeIfPresent(OpenRouterErrorEnvelope.self, forKey: .raw))?.error?.message
      }
    }
  }

  var code: Int?
  var message: String?
  var metadata: Metadata?

  enum CodingKeys: String, CodingKey {
    case code
    case message
    case metadata
  }

  init(code: Int? = nil, message: String? = nil, metadata: Metadata? = nil) {
    self.code = code
    self.message = message
    self.metadata = metadata
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try? container.decodeIfPresent(Int.self, forKey: .code)
    message = try? container.decodeIfPresent(String.self, forKey: .message)
    metadata = try? container.decodeIfPresent(Metadata.self, forKey: .metadata)
  }

  /// Any non-null `error` member counts as an error, even one of a shape the documentation does not describe.
  static func lenient<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> OpenRouterErrorBody? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
    return (try? container.decode(OpenRouterErrorBody.self, forKey: key)) ?? OpenRouterErrorBody()
  }
}

struct OpenRouterChunk: Decodable, Sendable {
  struct Choice: Decodable, Sendable {
    struct Delta: Decodable, Sendable {
      let content: String?
      let refusal: String?
    }

    let delta: Delta?
    let finishReason: String?
    let nativeFinishReason: String?
    let error: OpenRouterErrorBody?

    enum CodingKeys: String, CodingKey {
      case delta
      case finishReason = "finish_reason"
      case nativeFinishReason = "native_finish_reason"
      case error
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      delta = try container.decodeIfPresent(Delta.self, forKey: .delta)
      finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
      nativeFinishReason = try? container.decodeIfPresent(String.self, forKey: .nativeFinishReason)
      error = try OpenRouterErrorBody.lenient(in: container, forKey: .error)
    }
  }

  let id: String?
  let choices: [Choice]
  let usage: OpenRouterUsage?
  let error: OpenRouterErrorBody?

  enum CodingKeys: String, CodingKey {
    case id
    case choices
    case usage
    case error
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try? container.decodeIfPresent(String.self, forKey: .id)
    choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
    usage = try? container.decodeIfPresent(OpenRouterUsage.self, forKey: .usage)
    error = try OpenRouterErrorBody.lenient(in: container, forKey: .error)
  }
}

struct OpenRouterUsage: Decodable, Sendable, Equatable {
  struct PromptDetails: Decodable, Sendable, Equatable {
    let cachedTokens: OpenRouterCount?
    let cacheWriteTokens: OpenRouterCount?

    enum CodingKeys: String, CodingKey {
      case cachedTokens = "cached_tokens"
      case cacheWriteTokens = "cache_write_tokens"
    }
  }

  let promptTokens: OpenRouterCount?
  let completionTokens: OpenRouterCount?
  let promptTokensDetails: PromptDetails?
  let cost: OpenRouterAmount?

  enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case promptTokensDetails = "prompt_tokens_details"
    case cost
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    promptTokens = try? container.decodeIfPresent(OpenRouterCount.self, forKey: .promptTokens)
    completionTokens = try? container.decodeIfPresent(OpenRouterCount.self, forKey: .completionTokens)
    promptTokensDetails = try? container.decodeIfPresent(PromptDetails.self, forKey: .promptTokensDetails)
    cost = try? container.decodeIfPresent(OpenRouterAmount.self, forKey: .cost)
  }

  /// `prompt_tokens` includes cache reads and writes; a provider that reports them beside it instead would otherwise leave a negative uncached input.
  var tokenUsage: TokenUsage {
    let prompt = promptTokens?.value ?? 0
    let cacheRead = promptTokensDetails?.cachedTokens?.value ?? 0
    let cacheWrite = promptTokensDetails?.cacheWriteTokens?.value ?? 0
    let cached = cacheRead.addingReportingOverflow(cacheWrite)
    let input = cached.overflow || cached.partialValue > prompt ? prompt : prompt - cached.partialValue
    return TokenUsage(input: input, output: completionTokens?.value ?? 0, cacheRead: cacheRead, cacheWriteShort: cacheWrite)
  }
}

struct OpenRouterCount: Decodable, Sendable, Equatable {
  let value: Int?

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    value = (try? container.decode(Int.self)).flatMap { $0 >= 0 ? $0 : nil }
  }
}

struct OpenRouterKeyInfo: Decodable, Sendable {
  struct Details: Decodable, Sendable {
    let label: String?

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      label = try? container.decodeIfPresent(String.self, forKey: .label)
    }

    enum CodingKeys: String, CodingKey {
      case label
    }
  }

  let data: Details?
}

struct OpenRouterModelList: Decodable, Sendable {
  struct Entry: Decodable, Sendable {
    let model: RemoteModel?

    init(from decoder: any Decoder) throws {
      model = (try? OpenRouterModelEntry(from: decoder))?.remoteModel
    }
  }

  let data: [Entry]
}

private struct OpenRouterModelEntry: Decodable {
  struct Pricing: Decodable {
    let prompt: OpenRouterAmount?
    let completion: OpenRouterAmount?

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      prompt = try? container.decodeIfPresent(OpenRouterAmount.self, forKey: .prompt)
      completion = try? container.decodeIfPresent(OpenRouterAmount.self, forKey: .completion)
    }

    enum CodingKeys: String, CodingKey {
      case prompt
      case completion
    }
  }

  struct TopProvider: Decodable {
    let contextLength: OpenRouterCount?
    let maxCompletionTokens: OpenRouterCount?

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      contextLength = try? container.decodeIfPresent(OpenRouterCount.self, forKey: .contextLength)
      maxCompletionTokens = try? container.decodeIfPresent(OpenRouterCount.self, forKey: .maxCompletionTokens)
    }

    enum CodingKeys: String, CodingKey {
      case contextLength = "context_length"
      case maxCompletionTokens = "max_completion_tokens"
    }
  }

  static let structuredOutputsParameter = "structured_outputs"

  let id: String
  let name: String?
  let contextLength: OpenRouterCount?
  let topProvider: TopProvider?
  let supportedParameters: [String]?
  let pricing: Pricing?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case contextLength = "context_length"
    case topProvider = "top_provider"
    case supportedParameters = "supported_parameters"
    case pricing
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try? container.decodeIfPresent(String.self, forKey: .name)
    contextLength = try? container.decodeIfPresent(OpenRouterCount.self, forKey: .contextLength)
    topProvider = try? container.decodeIfPresent(TopProvider.self, forKey: .topProvider)
    supportedParameters = try? container.decodeIfPresent([String].self, forKey: .supportedParameters)
    pricing = try? container.decodeIfPresent(Pricing.self, forKey: .pricing)
  }

  var remoteModel: RemoteModel? {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return RemoteModel(
      id: id,
      name: name,
      contextLength: contextLength?.value ?? topProvider?.contextLength?.value,
      maxOutputTokens: topProvider?.maxCompletionTokens?.value,
      supportsJSONSchema: supportedParameters.map { $0.contains(Self.structuredOutputsParameter) },
      inputPrice: pricing?.prompt?.perMillionTokens,
      outputPrice: pricing?.completion?.perMillionTokens
    )
  }
}
