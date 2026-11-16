import Foundation
import Synchronization

public enum RedirectPolicy: Sendable {
  case follow
  case refuse

  fileprivate func resolve(_ request: URLRequest) -> URLRequest? {
    switch self {
    case .follow: request
    case .refuse: nil
    }
  }
}

public struct URLSessionTransport: HTTPTransport, HTTPStreamingTransport {
  private let owner: SessionOwner

  public init(configuration: URLSessionConfiguration = .ephemeral, redirects: RedirectPolicy = .refuse) {
    owner = SessionOwner(configuration: configuration, redirects: redirects)
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await owner.session.send(request)
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamingResponse {
    if Task.isCancelled { throw URLError(.cancelled) }

    let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let task = owner.session.dataTask(with: request)
    let delegate = StreamingTaskDelegate(redirects: owner.redirects, body: continuation)
    task.delegate = delegate
    continuation.onTermination = { termination in
      if case .cancelled = termination { task.cancel() }
    }

    let response = try await withTaskCancellationHandler {
      try await delegate.response { task.resume() }
    } onCancel: {
      delegate.fail(URLError(.cancelled))
      task.cancel()
    }
    return HTTPStreamingResponse(response: response, body: body)
  }
}

private final class SessionOwner: Sendable {
  let session: URLSession
  let redirects: RedirectPolicy

  init(configuration: URLSessionConfiguration, redirects: RedirectPolicy) {
    self.redirects = redirects
    session = URLSession(configuration: configuration, delegate: RedirectDelegate(redirects: redirects), delegateQueue: nil)
  }

  deinit {
    session.finishTasksAndInvalidate()
  }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  private let redirects: RedirectPolicy

  init(redirects: RedirectPolicy) {
    self.redirects = redirects
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(redirects.resolve(request))
  }
}

private final class StreamingTaskDelegate: NSObject, URLSessionDataDelegate, Sendable {
  private struct State {
    var waiter: CheckedContinuation<HTTPURLResponse, any Error>?
    var outcome: Result<HTTPURLResponse, any Error>?
    var chunker = LineChunker()
  }

  private let redirects: RedirectPolicy
  private let body: AsyncThrowingStream<Data, any Error>.Continuation
  private let state = Mutex(State())

  init(redirects: RedirectPolicy, body: AsyncThrowingStream<Data, any Error>.Continuation) {
    self.redirects = redirects
    self.body = body
  }

  func response(starting start: () -> Void) async throws -> HTTPURLResponse {
    try await withCheckedThrowingContinuation { continuation in
      let settled = state.withLock { state -> Result<HTTPURLResponse, any Error>? in
        if let outcome = state.outcome { return outcome }
        state.waiter = continuation
        return nil
      }
      guard let settled else { return start() }
      continuation.resume(with: settled)
    }
  }

  func fail(_ error: any Error) {
    settle(.failure(error))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(redirects.resolve(request))
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let httpResponse = response as? HTTPURLResponse else {
      settle(.failure(NetworkError.nonHTTPResponse))
      body.finish(throwing: NetworkError.nonHTTPResponse)
      return completionHandler(.cancel)
    }
    settle(.success(httpResponse))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let chunk = state.withLock({ $0.chunker.append(data) }) else { return }
    body.yield(chunk)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    settle(.failure(error ?? URLError(.badServerResponse)))
    let remainder = state.withLock { $0.chunker.drain() }
    if !remainder.isEmpty { body.yield(remainder) }
    guard let error else { return body.finish() }
    body.finish(throwing: error)
  }

  private func settle(_ outcome: Result<HTTPURLResponse, any Error>) {
    let waiter = state.withLock { state -> CheckedContinuation<HTTPURLResponse, any Error>? in
      guard state.outcome == nil else { return nil }
      state.outcome = outcome
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(with: outcome)
  }
}

private struct LineChunker {
  private static let flushThreshold = 16_384

  private var buffer = Data()

  mutating func append(_ data: Data) -> Data? {
    buffer.append(data)
    let boundary = buffer.count >= Self.flushThreshold ? buffer.endIndex : buffer.lastIndex { $0 == 0x0A || $0 == 0x0D }.map { $0 + 1 }
    guard let boundary else { return nil }
    let chunk = Data(buffer[..<boundary])
    buffer = Data(buffer[boundary...])
    return chunk
  }

  mutating func drain() -> Data {
    defer { buffer = Data() }
    return buffer
  }
}
