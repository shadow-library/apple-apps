import Foundation
import ShadowNetworking
import Testing

private let eventStream = ["Content-Type": "text/event-stream"]

@Suite("URLSessionTransport")
struct URLSessionTransportTests {
  private let transport = URLSessionTransport(configuration: ScriptedURLProtocol.configuration())

  @Test("should return the response as soon as the headers arrive")
  func returnsBeforeTheBody() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let body = Gate()
    ScriptedURLProtocol.register([.respond(status: 200, headers: eventStream), .wait(body), .send(Data("data: late\n\n".utf8)), .finish], at: url)

    let response = try await transport.stream(URLRequest(url: url))
    body.open()

    #expect(response.response.statusCode == 200)
    #expect(response.response.value(forHTTPHeaderField: "content-type") == "text/event-stream")
    #expect(try await collect(response.body) == [Data("data: late\n\n".utf8)])
  }

  @Test("should deliver streamed chunks in order as they arrive")
  func streamsInOrder() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let second = Gate()
    ScriptedURLProtocol.register(
      [.respond(status: 200, headers: eventStream), .send(Data("data: one\n\n".utf8)), .wait(second), .send(Data("data: two\n\n".utf8)), .finish],
      at: url
    )

    let response = try await transport.stream(URLRequest(url: url))
    var chunks = response.body.makeAsyncIterator()

    #expect(try await chunks.next() == Data("data: one\n\n".utf8))
    second.open()
    #expect(try await chunks.next() == Data("data: two\n\n".utf8))
    #expect(try await chunks.next() == nil)
  }

  @Test("should flush the body at line breaks and once 16 KB has accumulated")
  func flushesAtLineBreaksAndThreshold() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let head = ["data: par", "tial\n\ndata: x"].map { Data($0.utf8) }
    let tail = [String(repeating: "a", count: 20_000), "\r", "\ndata: y", "\n\n"].map { Data($0.utf8) }
    let rest = Gate()
    ScriptedURLProtocol.register([.respond(status: 200, headers: eventStream)] + head.map { .send($0) } + [.wait(rest)] + tail.map { .send($0) } + [.finish], at: url)

    let response = try await transport.stream(URLRequest(url: url))
    var iterator = response.body.makeAsyncIterator()
    var chunks = [try #require(try await iterator.next())]
    rest.open()
    while let chunk = try await iterator.next() { chunks.append(chunk) }

    #expect(chunks.first == Data("data: partial\n\n".utf8))
    #expect(chunks.reduce(Data(), +) == (head + tail).reduce(Data(), +))
    for chunk in chunks.dropLast() {
      #expect(chunk.last == UInt8(ascii: "\n") || chunk.last == UInt8(ascii: "\r") || chunk.count >= 16_384)
    }
    #expect(chunks.contains { $0.count >= 16_384 })
  }

  @Test("should surface a failure after the headers by throwing from the body")
  func throwsFromTheBody() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let failure = Gate()
    ScriptedURLProtocol.register([.respond(status: 200, headers: eventStream), .send(Data("data: a\n".utf8)), .wait(failure), .fail(URLError(.networkConnectionLost))], at: url)

    let response = try await transport.stream(URLRequest(url: url))
    var chunks = response.body.makeAsyncIterator()

    #expect(try await chunks.next() == Data("data: a\n".utf8))
    failure.open()
    let error = await #expect(throws: URLError.self) { try await chunks.next() }
    #expect(error?.code == .networkConnectionLost)
  }

  @Test("should not follow a redirect when redirects are refused")
  func refusesRedirects() async throws {
    let origin = try ScriptedURLProtocol.uniqueURL()
    let target = try ScriptedURLProtocol.uniqueURL()
    ScriptedURLProtocol.register([.redirect(to: target, status: 302), .send(Data("moved".utf8)), .finish], at: origin)
    let followed = ScriptedURLProtocol.register([.respond(status: 200, headers: [:]), .send(Data("followed".utf8)), .finish], at: target)

    let (data, sent) = try await transport.send(URLRequest(url: origin))
    let streamed = try await transport.stream(URLRequest(url: origin))

    #expect(sent.statusCode == 302)
    #expect(sent.value(forHTTPHeaderField: "location") == target.absoluteString)
    #expect(data == Data("moved".utf8))
    #expect(streamed.response.statusCode == 302)
    #expect(try await collect(streamed.body) == [Data("moved".utf8)])
    #expect(!followed.started.isOpen)
  }

  @Test("should follow a redirect when redirects are followed")
  func followsRedirects() async throws {
    let origin = try ScriptedURLProtocol.uniqueURL()
    let target = try ScriptedURLProtocol.uniqueURL()
    ScriptedURLProtocol.register([.redirect(to: target, status: 302), .send(Data("moved".utf8)), .finish], at: origin)
    ScriptedURLProtocol.register([.respond(status: 200, headers: [:]), .send(Data("followed".utf8)), .finish], at: target)
    let following = URLSessionTransport(configuration: ScriptedURLProtocol.configuration(), redirects: .follow)

    let (data, sent) = try await following.send(URLRequest(url: origin))
    let streamed = try await following.stream(URLRequest(url: origin))

    #expect(sent.statusCode == 200)
    #expect(data == Data("followed".utf8))
    #expect(streamed.response.statusCode == 200)
    #expect(try await collect(streamed.body) == [Data("followed".utf8)])
  }

  @Test("should cancel the request when the consuming task is cancelled")
  func cancelsWithTheConsumer() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let script = ScriptedURLProtocol.register([.respond(status: 200, headers: eventStream), .send(Data("data: one\n\n".utf8)), .hang], at: url)
    let response = try await transport.stream(URLRequest(url: url))
    let received = Gate()

    let consumer = Task {
      for try await _ in response.body { received.open() }
    }
    #expect(await received.waitUntilOpen())
    consumer.cancel()

    #expect(await script.stopped.waitUntilOpen())
    try await consumer.value
  }

  @Test("should cancel the request when the consumer stops iterating")
  func cancelsWhenIterationStops() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let script = ScriptedURLProtocol.register([.respond(status: 200, headers: eventStream), .send(Data("data: one\n\n".utf8)), .hang], at: url)

    try await firstChunk(of: transport.stream(URLRequest(url: url)))

    #expect(await script.stopped.waitUntilOpen())
  }

  @Test("should cancel the request when the task awaiting the headers is cancelled")
  func cancelsBeforeTheHeaders() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let script = ScriptedURLProtocol.register([.hang], at: url)
    let transport = transport

    let caller = Task { try await transport.stream(URLRequest(url: url)) }
    #expect(await script.started.waitUntilOpen())
    caller.cancel()

    let error = await #expect(throws: URLError.self) { try await caller.value }
    #expect(error?.code == .cancelled)
    #expect(await script.stopped.waitUntilOpen())
  }

  @Test("should capture lower-cased headers in unacceptableStatus through APIClient")
  func capturesHeadersOnStatusErrors() async throws {
    let url = try ScriptedURLProtocol.uniqueURL()
    let headers = ["Retry-After": "30", "X-Request-ID": "req_1", "Content-Type": "application/json"]
    ScriptedURLProtocol.register([.respond(status: 429, headers: headers), .send(Data(#"{"error":"rate_limited"}"#.utf8)), .finish], at: url.appending(path: "messages"))
    let client = APIClient(baseURL: url, transport: transport)

    let error = await #expect(throws: NetworkError.self) { try await client.send(Endpoint(method: .post, path: "messages", responseType: EmptyResponse.self)) }

    guard case .unacceptableStatus(let code, let received, let body) = error else {
      Issue.record("Unexpected error \(String(describing: error))")
      return
    }
    #expect(code == 429)
    #expect(received["retry-after"] == "30")
    #expect(received["x-request-id"] == "req_1")
    #expect(received["content-type"] == "application/json")
    #expect(body == Data(#"{"error":"rate_limited"}"#.utf8))
    #expect(error?.retryAfter == .seconds(30))
  }

  private func collect(_ body: AsyncThrowingStream<Data, any Error>) async throws -> [Data] {
    var chunks: [Data] = []
    for try await chunk in body { chunks.append(chunk) }
    return chunks
  }

  private func firstChunk(of response: HTTPStreamingResponse) async throws {
    for try await _ in response.body { break }
  }
}
