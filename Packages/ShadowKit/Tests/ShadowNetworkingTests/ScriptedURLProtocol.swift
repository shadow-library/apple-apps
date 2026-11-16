import Foundation
import Synchronization

final class Gate: Sendable {
  private let state = Mutex(false)

  var isOpen: Bool {
    state.withLock { $0 }
  }

  func open() {
    state.withLock { $0 = true }
  }

  func wait() async throws {
    while !isOpen { try await Task.sleep(for: .milliseconds(5)) }
  }

  func waitUntilOpen(timeout: Duration = .seconds(5)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !isOpen {
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }
}

struct Script: Sendable {
  enum Action: Sendable {
    case respond(status: Int, headers: [String: String])
    case send(Data)
    case wait(Gate)
    case redirect(to: URL, status: Int)
    case fail(URLError)
    case finish
    case hang
  }

  let actions: [Action]
  let started = Gate()
  let stopped = Gate()
}

/// `URLProtocolClient` calls take the protocol instance itself, so it has to cross into the script task; its own state is behind a `Mutex`.
final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
  private static let scripts = Mutex<[URL: Script]>([:])

  private let runner = Mutex<Task<Void, Never>?>(nil)

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedURLProtocol.self]
    return configuration
  }

  @discardableResult
  static func register(_ actions: [Script.Action], at url: URL) -> Script {
    let script = Script(actions: actions)
    scripts.withLock { $0[url] = script }
    return script
  }

  static func uniqueURL() throws -> URL {
    guard let url = URL(string: "https://scripted.test/\(UUID().uuidString)") else { throw URLError(.badURL) }
    return url
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let script = Self.scripts.withLock({ $0[url] }) else {
      return client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) ?? ()
    }
    script.started.open()
    let task = Task { await self.run(script, url: url) }
    runner.withLock { $0 = task }
  }

  override func stopLoading() {
    runner.withLock { $0?.cancel() }
    guard let url = request.url, let script = Self.scripts.withLock({ $0[url] }) else { return }
    script.stopped.open()
  }

  private func run(_ script: Script, url: URL) async {
    guard let client else { return }
    do {
      for action in script.actions {
        try Task.checkCancellation()
        switch action {
        case .respond(let status, let headers):
          guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { throw URLError(.badServerResponse) }
          client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case .send(let data):
          client.urlProtocol(self, didLoad: data)
        case .wait(let gate):
          try await gate.wait()
        case .redirect(let target, let status):
          let headers = ["Location": target.absoluteString]
          guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { throw URLError(.badServerResponse) }
          client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
          // A followed redirect stops this protocol; a refused one gets no signal and must deliver the 3xx itself.
          try await Task.sleep(for: .milliseconds(100))
          client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case .fail(let error):
          return client.urlProtocol(self, didFailWithError: error)
        case .finish:
          return client.urlProtocolDidFinishLoading(self)
        case .hang:
          while true { try await Task.sleep(for: .seconds(60)) }
        }
      }
    } catch {
      return
    }
  }
}
