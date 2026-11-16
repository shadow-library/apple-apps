import Foundation
import ShadowNetworking
import ShadowTestSupport
import Testing

@Suite("StubHTTPExchangeTransport")
struct StubHTTPExchangeTransportTests {
  private static func request(_ path: String) throws -> URLRequest {
    URLRequest(url: try #require(URL(string: "https://api.example.com/\(path)")))
  }

  @Test("should answer plain and streamed requests and record both kinds in order")
  func recordsInOrder() async throws {
    let transport = StubHTTPExchangeTransport(
      plain: StubHTTPTransport(statusCode: 201, json: "{}"),
      streaming: StubHTTPStreamingTransport(status: 202, headers: ["X-A": "b"], steps: [.text("data: one\n\n")])
    )

    _ = try await transport.send(Self.request("one"))
    let streamed = try await transport.stream(Self.request("two"))
    let (data, plain) = try await transport.send(Self.request("three"))
    var chunks: [Data] = []
    for try await chunk in streamed.body { chunks.append(chunk) }

    #expect(plain.statusCode == 201)
    #expect(data == Data("{}".utf8))
    #expect(streamed.response.statusCode == 202)
    #expect(streamed.response.value(forHTTPHeaderField: "x-a") == "b")
    #expect(chunks == [Data("data: one\n\n".utf8)])
    #expect(transport.requests.map { $0.url?.path() } == ["/one", "/two", "/three"])
    #expect(transport.plain.requests.map { $0.url?.path() } == ["/one", "/three"])
    #expect(transport.streaming.requests.map { $0.url?.path() } == ["/two"])
  }

  @Test("should build a streaming-only stub from a status and steps")
  func buildsFromSteps() async throws {
    let transport = StubHTTPExchangeTransport(status: 500, headers: ["Retry-After": "2"], steps: [.text("boom")])

    let response = try await transport.stream(Self.request("x"))

    #expect(response.response.statusCode == 500)
    #expect(response.response.value(forHTTPHeaderField: "Retry-After") == "2")
  }

  @Test("should replay scripted failures of either kind")
  func replaysFailures() async throws {
    let transport = StubHTTPExchangeTransport(
      plain: StubHTTPTransport(error: URLError(.timedOut)),
      streaming: StubHTTPStreamingTransport(steps: [.text("data: a\n\n"), .failure(URLError(.networkConnectionLost))])
    )

    let plainError = await #expect(throws: URLError.self) { try await transport.send(Self.request("p")) }
    let response = try await transport.stream(Self.request("s"))
    let bodyError = await #expect(throws: URLError.self) {
      for try await _ in response.body {}
    }

    #expect(plainError?.code == .timedOut)
    #expect(bodyError?.code == .networkConnectionLost)
    #expect(transport.requests.count == 2)
  }

  @Test("should fail an unscripted plain request clearly and still record it")
  func failsUnscriptedPlain() async throws {
    let transport = StubHTTPExchangeTransport(streaming: StubHTTPStreamingTransport(steps: []))
    let request = try Self.request("models")

    let error = await #expect(throws: StubHTTPExchangeTransport.UnscriptedRequest.self) { try await transport.send(request) }

    #expect(error == StubHTTPExchangeTransport.UnscriptedRequest(kind: .plain, url: request.url))
    #expect(error?.description.contains("plain") == true)
    #expect(error?.description.contains("https://api.example.com/models") == true)
    #expect(transport.requests.count == 1)
  }

  @Test("should fail an unscripted streamed request clearly and still record it")
  func failsUnscriptedStreaming() async throws {
    let transport = StubHTTPExchangeTransport(plain: StubHTTPTransport(json: "{}"))
    let request = try Self.request("chat")

    let error = await #expect(throws: StubHTTPExchangeTransport.UnscriptedRequest.self) { try await transport.stream(request) }

    #expect(error == StubHTTPExchangeTransport.UnscriptedRequest(kind: .streaming, url: request.url))
    #expect(error?.description.contains("streaming") == true)
    #expect(transport.requests.count == 1)
  }

  @Test("should fail every request of a stub with nothing scripted")
  func failsWhenEmpty() async throws {
    let transport = StubHTTPExchangeTransport()

    await #expect(throws: StubHTTPExchangeTransport.UnscriptedRequest.self) { try await transport.send(Self.request("a")) }
    await #expect(throws: StubHTTPExchangeTransport.UnscriptedRequest.self) { try await transport.stream(Self.request("b")) }
    #expect(transport.requests.count == 2)
  }

  @Test("should count a body whose reader stopped early, and not one read to its end")
  func countsCancelledBodies() async throws {
    let transport = StubHTTPExchangeTransport(status: 200, steps: [.text("data: a\n\n"), .delay(.seconds(60)), .text("data: b\n\n")])

    let finished = try await StubHTTPExchangeTransport(status: 200, steps: [.text("data: a\n\n")]).stream(Self.request("done"))
    for try await _ in finished.body {}
    do {
      let response = try await transport.stream(Self.request("early"))
      var iterator = response.body.makeAsyncIterator()
      _ = try await iterator.next()
    }

    #expect(transport.cancelledBodies == 1)
    #expect(transport.plain.requests.isEmpty)
  }
}
