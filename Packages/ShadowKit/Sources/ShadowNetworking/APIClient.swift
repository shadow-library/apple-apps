import Foundation

public struct APIClient: Sendable {
  public let baseURL: URL
  private let transport: any HTTPTransport
  private let middlewares: [any HTTPMiddleware]
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    baseURL: URL,
    transport: any HTTPTransport = URLSession.shared,
    middlewares: [any HTTPMiddleware] = [],
    encoder: JSONEncoder = .shadow(),
    decoder: JSONDecoder = .shadow()
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.middlewares = middlewares
    self.encoder = encoder
    self.decoder = decoder
  }

  public func send<Response>(_ endpoint: Endpoint<Response>) async throws(NetworkError) -> Response {
    let request = try makeRequest(for: endpoint)
    let (data, response) = try await perform(request)
    guard (200..<300).contains(response.statusCode) else { throw .unacceptableStatus(code: response.statusCode, headers: response.lowercasedHeaderFields, body: data) }
    if let empty = EmptyResponse() as? Response { return empty }

    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw .decoding(String(describing: error))
    }
  }

  private func makeRequest<Response>(for endpoint: Endpoint<Response>) throws(NetworkError) -> URLRequest {
    var url = baseURL.appending(path: endpoint.path)
    if !endpoint.queryItems.isEmpty { url.append(queryItems: endpoint.queryItems) }

    var request = URLRequest(url: url)
    request.httpMethod = endpoint.method.rawValue
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let body = endpoint.body {
      do {
        request.httpBody = try encoder.encode(body)
      } catch {
        throw .encoding(String(describing: error))
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    for (field, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: field) }
    return request
  }

  private func perform(_ request: URLRequest) async throws(NetworkError) -> (Data, HTTPURLResponse) {
    do {
      return try await dispatch(request, through: middlewares[...])
    } catch let error as NetworkError {
      throw error
    } catch is CancellationError {
      throw .cancelled
    } catch let error as URLError {
      throw error.code == .cancelled ? .cancelled : .transport(error)
    } catch {
      throw .underlying(error)
    }
  }

  private func dispatch(_ request: URLRequest, through remaining: ArraySlice<any HTTPMiddleware>) async throws -> (Data, HTTPURLResponse) {
    guard let middleware = remaining.first else { return try await transport.send(request) }
    return try await middleware.intercept(request) { try await dispatch($0, through: remaining.dropFirst()) }
  }
}
