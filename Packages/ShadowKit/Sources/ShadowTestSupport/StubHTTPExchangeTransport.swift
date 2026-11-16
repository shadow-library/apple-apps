import Foundation
import ShadowNetworking
import Synchronization

public final class StubHTTPExchangeTransport: HTTPTransport, HTTPStreamingTransport {
  public struct UnscriptedRequest: Error, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
      case plain
      case streaming
    }

    public let kind: Kind
    public let url: URL?

    public init(kind: Kind, url: URL?) {
      self.kind = kind
      self.url = url
    }

    public var description: String { "StubHTTPExchangeTransport has no \(kind) response scripted for \(url?.absoluteString ?? "a request without a URL")." }
  }

  public let plain: StubHTTPTransport
  public let streaming: StubHTTPStreamingTransport
  private let recorded = Mutex<[URLRequest]>([])
  private let cancelled = Mutex<Int>(0)

  public init(plain: StubHTTPTransport? = nil, streaming: StubHTTPStreamingTransport? = nil) {
    self.plain = plain ?? StubHTTPTransport { request in throw UnscriptedRequest(kind: .plain, url: request.url) }
    self.streaming = streaming ?? StubHTTPStreamingTransport { request in throw UnscriptedRequest(kind: .streaming, url: request.url) }
  }

  public convenience init(status: Int = 200, headers: [String: String] = [:], steps: [StubHTTPStreamingTransport.Step]) {
    self.init(streaming: StubHTTPStreamingTransport(status: status, headers: headers, steps: steps))
  }

  public var requests: [URLRequest] {
    recorded.withLock { $0 }
  }

  public var cancelledBodies: Int {
    cancelled.withLock { $0 }
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorded.withLock { $0.append(request) }
    return try await plain.send(request)
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamingResponse {
    recorded.withLock { $0.append(request) }
    let scripted = try await streaming.stream(request)
    return HTTPStreamingResponse(response: scripted.response, body: observing(scripted.body))
  }

  private func observing(_ source: AsyncThrowingStream<Data, any Error>) -> AsyncThrowingStream<Data, any Error> {
    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let forwarder = Task {
      do {
        for try await chunk in source { continuation.yield(chunk) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { [self] reason in
      forwarder.cancel()
      guard case .cancelled = reason else { return }
      cancelled.withLock { $0 += 1 }
    }
    return body
  }
}
