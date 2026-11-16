import Foundation
import ShadowCore
import ShadowNetworking

public struct OpenRouterProvider: ModelProvider {
  public typealias Transport = any HTTPTransport & HTTPStreamingTransport

  private static let endOfBody = Data("\n\n".utf8)
  private static let oversizedReply = ModelError.malformedResponse("The reply holds a line or event larger than allowed.")

  private let configuration: OpenRouterConfiguration
  private let credential: @Sendable () async throws(ModelError) -> ProviderCredential
  private let transport: Transport
  private let trustedClock: TrustedClock?

  public init(
    configuration: OpenRouterConfiguration = .init(),
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
      let request = try request.validated()
      let key = try await credential()
      let urlRequest = try makeChatRequest(request, credential: key)
      let response: HTTPStreamingResponse
      do {
        response = try await transport.stream(urlRequest)
      } catch {
        throw ModelError(converting: error)
      }
      record(response.response)
      guard (200..<300).contains(response.response.statusCode) else { throw await OpenRouterFailure.response(response, secret: key.secret) }
      var state = OpenRouterStreamState(secret: key.secret)
      if let started = state.start(generationHeader: response.response.value(forHTTPHeaderField: "X-Generation-Id")) { try continuation.yield(started) }
      var parser = ServerSentEventParser()
      do {
        for try await bytes in response.body {
          try deliver(bytes, parsedBy: &parser, into: &state, continuation: continuation)
          if state.isDone { break }
        }
      } catch {
        throw ModelError(converting: error)
      }
      if Task.isCancelled { throw .cancelled }
      if !state.isDone { try deliver(Self.endOfBody, parsedBy: &parser, into: &state, continuation: continuation) }
      try continuation.yield(try state.finished())
    }
  }

  public func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    let url = configuration.keyURL
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    try authorize(&request, with: credential)
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      let failure = ModelError(converting: error)
      if failure == .cancelled { throw failure }
      return .unverified(failure)
    }
    record(response)
    if (200..<300).contains(response.statusCode) {
      let label = (try? JSONDecoder().decode(OpenRouterKeyInfo.self, from: data))?.data?.label
      return .valid(label: label.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 })
    }
    if response.statusCode == 401 { return .invalid }
    return .unverified(OpenRouterFailure.response(response, body: data, secret: credential.secret))
  }

  public func models() async throws(ModelError) -> [RemoteModel] {
    var request = URLRequest(url: configuration.modelsURL)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      throw ModelError(converting: error)
    }
    record(response)
    guard (200..<300).contains(response.statusCode) else { throw OpenRouterFailure.response(response, body: data, secret: nil) }
    do {
      return try JSONDecoder().decode(OpenRouterModelList.self, from: data).data.compactMap(\.model)
    } catch {
      throw .malformedResponse("The provider's model list could not be read.")
    }
  }

  private func makeChatRequest(_ request: ModelRequest, credential: ProviderCredential) throws(ModelError) -> URLRequest {
    var urlRequest = URLRequest(url: configuration.chatCompletionsURL)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (field, value) in configuration.attributionHeaders { urlRequest.setValue(value, forHTTPHeaderField: field) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      urlRequest.httpBody = try encoder.encode(OpenRouterRequestBody(request))
    } catch {
      throw .invalidRequest("The request could not be encoded.")
    }
    try authorize(&urlRequest, with: credential)
    return urlRequest
  }

  private func authorize(_ request: inout URLRequest, with credential: ProviderCredential) throws(ModelError) {
    guard let url = request.url, credential.authorizes(url) else { throw .invalidRequest("The key belongs to another origin, so it was not sent.") }
    guard credential.secret.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw .invalidRequest("The key holds characters a request header cannot carry.") }
    request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
  }

  private func deliver(_ bytes: Data, parsedBy parser: inout ServerSentEventParser, into state: inout OpenRouterStreamState, continuation: ModelStream.Continuation)
    throws(ModelError)
  {
    let events: [ServerSentEvent]
    do {
      events = try parser.parse(bytes)
    } catch {
      throw Self.oversizedReply
    }
    for event in events {
      try state.ingest(event.data) { modelEvent throws(ModelError) in try continuation.yield(modelEvent) }
      if state.isDone { return }
    }
    if parser.failure != nil { throw Self.oversizedReply }
  }

  private func record(_ response: HTTPURLResponse) {
    guard let trustedClock, let date = response.value(forHTTPHeaderField: "Date") else { return }
    trustedClock.record(httpDateHeader: date)
  }
}
