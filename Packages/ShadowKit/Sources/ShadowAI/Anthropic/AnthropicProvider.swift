import Foundation
import ShadowCore
import ShadowNetworking

public struct AnthropicProvider: ModelProvider {
  public typealias Transport = any HTTPTransport & HTTPStreamingTransport

  private static let errorBodyLimit = 65_536
  private static let modelPageSize = 1_000
  private static let modelPageLimit = 100
  private static let foreignKey = ModelError.invalidRequest("The key belongs to a different address than this provider.")

  public let configuration: AnthropicConfiguration
  private let credential: @Sendable () async throws(ModelError) -> ProviderCredential
  private let transport: Transport
  private let trustedClock: TrustedClock?

  public init(
    configuration: AnthropicConfiguration = .init(),
    credential: @escaping @Sendable () async throws(ModelError) -> ProviderCredential,
    transport: Transport,
    trustedClock: TrustedClock? = nil
  ) {
    self.configuration = configuration
    self.credential = credential
    self.transport = transport
    self.trustedClock = trustedClock
  }

  public func stream(_ request: ModelRequest) -> ModelStream {
    ModelStream { continuation throws(ModelError) in
      let body = try AnthropicRequestBody(request.validated()).encoded()
      var urlRequest = try authorized(configuration.messagesURL, with: try await self.credential(), timeout: configuration.idleTimeout)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.httpBody = body
      let response = try await open(urlRequest)
      var decoder = AnthropicStreamDecoder(requestID: response.response.value(forHTTPHeaderField: "request-id"))
      do {
        for try await event in response.body.serverSentEvents() {
          for modelEvent in try decoder.consume(event) { try continuation.yield(modelEvent) }
          if decoder.isComplete { return }
        }
      } catch {
        throw ModelError(converting: error)
      }
      if Task.isCancelled { throw .cancelled }
      throw .malformedResponse("The reply ended before it finished.")
    }
  }

  public func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    let url = configuration.modelsURL(limit: 1, after: nil)
    guard credential.authorizes(url) else { throw Self.foreignKey }
    do throws(ModelError) {
      _ = try await modelPage(at: url, with: credential)
      return .valid(label: nil)
    } catch .authentication {
      return .invalid
    } catch .cancelled {
      throw .cancelled
    } catch {
      return .unverified(error)
    }
  }

  public func models() async throws(ModelError) -> [RemoteModel] {
    let credential = try await self.credential()
    var models: [RemoteModel] = []
    var cursor: String?
    var cursors: Set<String> = []
    for _ in 0..<Self.modelPageLimit {
      let page = try await modelPage(at: configuration.modelsURL(limit: Self.modelPageSize, after: cursor), with: credential)
      models += page.data.map(\.remote)
      guard page.hasMore else { return models }
      guard let next = page.lastID, cursors.insert(next).inserted else { throw .malformedResponse("The provider's model list does not say where its next page starts.") }
      cursor = next
    }
    throw .malformedResponse("The provider's model list has too many pages.")
  }

  private func authorized(_ url: URL, with credential: ProviderCredential, timeout: Duration) throws(ModelError) -> URLRequest {
    guard credential.authorizes(url) else { throw Self.foreignKey }
    let components = timeout.components
    var request = URLRequest(url: url, timeoutInterval: TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18)
    request.setValue(credential.secret, forHTTPHeaderField: "x-api-key")
    request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
    return request
  }

  private func open(_ request: URLRequest) async throws(ModelError) -> HTTPStreamingResponse {
    let streaming: HTTPStreamingResponse
    do {
      streaming = try await transport.stream(request)
    } catch {
      throw ModelError(converting: error)
    }
    record(streaming.response)
    guard (200..<300).contains(streaming.response.statusCode) else {
      let body = await Self.collect(streaming.body, limit: Self.errorBodyLimit)
      if Task.isCancelled { throw .cancelled }
      throw AnthropicErrors.http(status: streaming.response.statusCode, headers: Self.headers(of: streaming.response), body: body)
    }
    return streaming
  }

  private func modelPage(at url: URL, with credential: ProviderCredential) async throws(ModelError) -> AnthropicModelPage {
    let request = try authorized(url, with: credential, timeout: AnthropicConfiguration.lookupTimeout)
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      throw ModelError(converting: error)
    }
    record(response)
    guard (200..<300).contains(response.statusCode) else { throw AnthropicErrors.http(status: response.statusCode, headers: Self.headers(of: response), body: data) }
    do {
      return try JSONDecoder().decode(AnthropicModelPage.self, from: data)
    } catch {
      throw .malformedResponse("The provider's model list could not be read.")
    }
  }

  private func record(_ response: HTTPURLResponse) {
    guard let trustedClock, let date = response.value(forHTTPHeaderField: "Date") else { return }
    trustedClock.record(httpDateHeader: date)
  }

  private static func collect(_ body: AsyncThrowingStream<Data, any Error>, limit: Int) async -> Data {
    var data = Data()
    do {
      for try await chunk in body {
        data.append(chunk.prefix(limit - data.count))
        if data.count >= limit { break }
      }
    } catch {
      return data
    }
    return data
  }

  private static func headers(of response: HTTPURLResponse) -> [String: String] {
    var headers: [String: String] = [:]
    for (name, value) in response.allHeaderFields {
      guard let name = name as? String, let value = value as? String else { continue }
      headers[name.lowercased()] = value
    }
    return headers
  }
}
