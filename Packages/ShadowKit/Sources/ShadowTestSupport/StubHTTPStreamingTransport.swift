import Foundation
import ShadowNetworking
import Synchronization

public final class StubHTTPStreamingTransport: HTTPStreamingTransport {
  public enum Step: Sendable {
    case chunk(Data)
    case text(String)
    case delay(Duration)
    case failure(URLError)
  }

  public typealias Handler = @Sendable (URLRequest) async throws -> HTTPStreamingResponse

  private let handler: Handler
  private let recorded = Mutex<[URLRequest]>([])

  public init(handler: @escaping Handler) {
    self.handler = handler
  }

  public convenience init(status: Int = 200, headers: [String: String] = [:], steps: [Step]) {
    self.init { request in try Self.response(to: request, status: status, headers: headers, steps: steps) }
  }

  public var requests: [URLRequest] {
    recorded.withLock { $0 }
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamingResponse {
    recorded.withLock { $0.append(request) }
    return try await handler(request)
  }

  public static func response(to request: URLRequest, status: Int = 200, headers: [String: String] = [:], steps: [Step]) throws -> HTTPStreamingResponse {
    guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
      throw URLError(.badURL)
    }
    return HTTPStreamingResponse(response: response, body: body(playing: steps))
  }

  private static func body(playing steps: [Step]) -> AsyncThrowingStream<Data, any Error> {
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let player = Task {
      for step in steps {
        switch step {
        case .chunk(let data):
          continuation.yield(data)
        case .text(let text):
          continuation.yield(Data(text.utf8))
        case .delay(let duration):
          try? await Task.sleep(for: duration)
          if Task.isCancelled { return }
        case .failure(let error):
          return continuation.finish(throwing: error)
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in player.cancel() }
    return body
  }
}
