import Foundation
import ShadowNetworking
import ShadowTestSupport
import Testing

private struct User: Codable, Sendable, Equatable {
  let id: Int
  let name: String
  let createdAt: Date
}

private let baseURL = URL(string: "https://api.example.com/v1")

@Suite("APIClient")
struct APIClientTests {
  @Test("should build the request from the endpoint and decode the response")
  func buildsRequestAndDecodes() async throws {
    let transport = StubHTTPTransport(json: #"{"id":1,"name":"Ada","createdAt":"2026-11-14T10:00:00.123Z"}"#)
    let client = APIClient(baseURL: try #require(baseURL), transport: transport)

    let user = try await client.send(Endpoint(path: "users/1", queryItems: [URLQueryItem(name: "expand", value: "profile")], responseType: User.self))

    #expect(user.id == 1)
    #expect(user.name == "Ada")
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://api.example.com/v1/users/1?expand=profile")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test("should accept ISO 8601 dates without fractional seconds")
  func decodesDatesWithoutFractionalSeconds() async throws {
    let transport = StubHTTPTransport(json: #"{"id":1,"name":"Ada","createdAt":"2026-11-14T10:00:00Z"}"#)
    let client = APIClient(baseURL: try #require(baseURL), transport: transport)

    let user = try await client.send(Endpoint(path: "users/1", responseType: User.self))

    #expect(user.createdAt == Date(timeIntervalSince1970: 1_794_650_400))
  }

  @Test("should encode the body as JSON")
  func encodesBody() async throws {
    let transport = StubHTTPTransport(statusCode: 204)
    let client = APIClient(baseURL: try #require(baseURL), transport: transport)
    let user = User(id: 2, name: "Grace", createdAt: Date(timeIntervalSince1970: 0))

    _ = try await client.send(Endpoint(method: .post, path: "users", body: user, responseType: EmptyResponse.self))

    let request = try #require(transport.requests.first)
    let body = try #require(request.httpBody)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(try JSONDecoder.shadow().decode(User.self, from: body) == user)
  }

  @Test("should throw unacceptableStatus for non-2xx responses")
  func throwsOnErrorStatus() async throws {
    let client = APIClient(baseURL: try #require(baseURL), transport: StubHTTPTransport(statusCode: 404, json: #"{"message":"not found"}"#))

    let error = await #expect(throws: NetworkError.self) { try await client.send(Endpoint(path: "users/9", responseType: User.self)) }

    guard case .unacceptableStatus(let code, _, _) = error else {
      Issue.record("Unexpected error \(String(describing: error))")
      return
    }
    #expect(code == 404)
  }

  @Test("should throw decoding when the payload does not match")
  func throwsOnDecodingFailure() async throws {
    let client = APIClient(baseURL: try #require(baseURL), transport: StubHTTPTransport(json: #"{"unexpected":true}"#))

    let error = await #expect(throws: NetworkError.self) { try await client.send(Endpoint(path: "users/1", responseType: User.self)) }

    guard case .decoding = error else {
      Issue.record("Unexpected error \(String(describing: error))")
      return
    }
  }

  @Test("should map URL errors to transport and cancellation")
  func mapsURLErrors() async throws {
    let offline = APIClient(baseURL: try #require(baseURL), transport: StubHTTPTransport(error: URLError(.notConnectedToInternet)))
    let cancelled = APIClient(baseURL: try #require(baseURL), transport: StubHTTPTransport(error: URLError(.cancelled)))

    let offlineError = await #expect(throws: NetworkError.self) { try await offline.send(Endpoint(path: "users", responseType: EmptyResponse.self)) }
    let cancelledError = await #expect(throws: NetworkError.self) { try await cancelled.send(Endpoint(path: "users", responseType: EmptyResponse.self)) }

    guard case .transport(let urlError) = offlineError else {
      Issue.record("Unexpected error \(String(describing: offlineError))")
      return
    }
    #expect(urlError.code == .notConnectedToInternet)
    guard case .cancelled = cancelledError else {
      Issue.record("Unexpected error \(String(describing: cancelledError))")
      return
    }
  }

  @Test("should run middlewares in order before the transport")
  func runsMiddlewares() async throws {
    let transport = StubHTTPTransport(statusCode: 204)
    let client = APIClient(
      baseURL: try #require(baseURL),
      transport: transport,
      middlewares: [BearerTokenMiddleware { "token-123" }, HeaderMiddleware(field: "Authorization", value: "overridden")]
    )

    _ = try await client.send(Endpoint(path: "me", responseType: EmptyResponse.self))

    #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "overridden")
  }

  @Test("should skip the Authorization header when there is no token")
  func skipsMissingToken() async throws {
    let transport = StubHTTPTransport(statusCode: 204)
    let client = APIClient(baseURL: try #require(baseURL), transport: transport, middlewares: [BearerTokenMiddleware { nil }])

    _ = try await client.send(Endpoint(path: "me", responseType: EmptyResponse.self))

    #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
  }
}

private struct HeaderMiddleware: HTTPMiddleware {
  let field: String
  let value: String

  func intercept(_ request: URLRequest, next: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
    var request = request
    request.setValue(value, forHTTPHeaderField: field)
    return try await next(request)
  }
}
