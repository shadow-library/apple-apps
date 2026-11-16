import Foundation

public struct HTTPStreamingResponse: Sendable {
  public let response: HTTPURLResponse
  public let body: AsyncThrowingStream<Data, any Error>

  public init(response: HTTPURLResponse, body: AsyncThrowingStream<Data, any Error>) {
    self.response = response
    self.body = body
  }
}

public protocol HTTPStreamingTransport: Sendable {
  func stream(_ request: URLRequest) async throws -> HTTPStreamingResponse
}
