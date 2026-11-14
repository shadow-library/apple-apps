import Foundation
import ShadowNetworking
import Synchronization

public final class StubHTTPTransport: HTTPTransport {
  public typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let handler: Handler
  private let recorded = Mutex<[URLRequest]>([])

  public init(handler: @escaping Handler) {
    self.handler = handler
  }

  public convenience init(statusCode: Int = 200, json: String = "") {
    self.init { request in try Self.response(to: request, statusCode: statusCode, data: Data(json.utf8)) }
  }

  public convenience init(error: URLError) {
    self.init { _ in throw error }
  }

  public var requests: [URLRequest] {
    recorded.withLock { $0 }
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorded.withLock { $0.append(request) }
    return try await handler(request)
  }

  public static func response(to request: URLRequest, statusCode: Int, data: Data = Data(), headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
    guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers) else {
      throw URLError(.badURL)
    }
    return (data, response)
  }
}
