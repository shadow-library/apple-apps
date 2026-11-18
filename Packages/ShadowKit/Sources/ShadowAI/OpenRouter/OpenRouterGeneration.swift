import Foundation
import ShadowNetworking

public struct OpenRouterGeneration: Sendable, Equatable {
  public let id: String
  public let cost: Cost
  public let nativeInputTokens: Int?
  public let nativeOutputTokens: Int?
}

public enum OpenRouterGenerationError: Error, Sendable, Equatable {
  case notReady
  case authentication
  case rateLimited(retryAfter: Duration?)
  case server(status: Int)
  case transport(URLError.Code)
  case rejected(status: Int)
  case malformed
  case cancelled

  public var isRetryable: Bool {
    switch self {
    case .notReady, .rateLimited, .server, .transport: true
    case .authentication, .rejected, .malformed, .cancelled: false
    }
  }
}

/// The reference platform reads `usage.cost` from the stream only; the path and the `data.total_cost` and `data.native_tokens_*` fields follow
/// https://openrouter.ai/docs/api-reference/get-a-generation.
public struct OpenRouterGenerationLookup: Sendable {
  private let configuration: OpenRouterConfiguration
  private let credential: @Sendable () async throws(ModelError) -> ProviderCredential
  private let transport: any HTTPTransport

  public init(
    configuration: OpenRouterConfiguration = .init(),
    credential: @escaping @Sendable () async throws(ModelError) -> ProviderCredential,
    transport: any HTTPTransport
  ) {
    self.configuration = configuration
    self.credential = credential
    self.transport = transport
  }

  public var provider: String? { configuration.origin.host(percentEncoded: false)?.lowercased() }

  public func generation(id: String) async throws(OpenRouterGenerationError) -> OpenRouterGeneration {
    let request = try await makeRequest(id: id)
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      switch ModelError(converting: error) {
      case .cancelled: throw .cancelled
      case .transport(let code): throw .transport(code)
      default: throw .transport(.unknown)
      }
    }
    try Self.check(response)
    return try Self.parse(data, id: id)
  }

  private func makeRequest(id: String) async throws(OpenRouterGenerationError) -> URLRequest {
    let key: ProviderCredential
    do {
      key = try await credential()
    } catch {
      throw error == .cancelled ? .cancelled : .authentication
    }
    guard var components = URLComponents(url: configuration.generationURL, resolvingAgainstBaseURL: false) else { throw .malformed }
    components.queryItems = [URLQueryItem(name: "id", value: id)]
    guard let url = components.url, key.authorizes(url), key.secret.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw .authentication }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(key.secret)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func check(_ response: HTTPURLResponse) throws(OpenRouterGenerationError) {
    switch response.statusCode {
    case 200..<300: return
    case 401, 403: throw .authentication
    case 404: throw .notReady
    case 429: throw .rateLimited(retryAfter: OpenRouterFailure.retryAfter(response))
    case 500...599: throw .server(status: response.statusCode)
    default: throw .rejected(status: response.statusCode)
    }
  }

  private static func parse(_ data: Data, id: String) throws(OpenRouterGenerationError) -> OpenRouterGeneration {
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let fields = envelope.data else { throw .malformed }
    guard let amount = fields.totalCost else { throw .notReady }
    guard let cost = amount.nanoUSD else { throw .malformed }
    return OpenRouterGeneration(id: id, cost: cost, nativeInputTokens: fields.nativeInput, nativeOutputTokens: fields.nativeOutput)
  }

  private struct Envelope: Decodable {
    let data: Fields?
  }

  private struct Fields: Decodable {
    let totalCost: OpenRouterAmount?
    let nativeInput: Int?
    let nativeOutput: Int?

    enum CodingKeys: String, CodingKey {
      case totalCost = "total_cost"
      case nativeInput = "native_tokens_prompt"
      case nativeOutput = "native_tokens_completion"
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      totalCost = try? container.decodeIfPresent(OpenRouterAmount.self, forKey: .totalCost)
      nativeInput = try? container.decodeIfPresent(Int.self, forKey: .nativeInput)
      nativeOutput = try? container.decodeIfPresent(Int.self, forKey: .nativeOutput)
    }
  }
}
