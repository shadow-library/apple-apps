import Foundation
import ShadowNetworking
import ShadowTestSupport
import Testing

@Suite("StubHTTPStreamingTransport")
struct StubHTTPStreamingTransportTests {
  @Test("should deliver scripted chunks, text and delays in order with the scripted head")
  func deliversSteps() async throws {
    let transport = StubHTTPStreamingTransport(
      status: 201,
      headers: ["Content-Type": "text/event-stream"],
      steps: [.chunk(Data("data: one\n\n".utf8)), .delay(.milliseconds(20)), .text("data: two\n\n")]
    )
    let request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1/messages")))
    let clock = ContinuousClock()
    let start = clock.now

    let response = try await transport.stream(request)
    var chunks: [Data] = []
    for try await chunk in response.body { chunks.append(chunk) }

    #expect(response.response.statusCode == 201)
    #expect(response.response.value(forHTTPHeaderField: "content-type") == "text/event-stream")
    #expect(chunks == [Data("data: one\n\n".utf8), Data("data: two\n\n".utf8)])
    #expect(clock.now - start >= .milliseconds(20))
    #expect(transport.requests.map(\.url) == [request.url])
  }

  @Test("should fail the body mid-stream and skip the remaining steps")
  func failsMidStream() async throws {
    let transport = StubHTTPStreamingTransport(steps: [.text("data: a\n\n"), .failure(URLError(.networkConnectionLost)), .text("data: never\n\n")])
    let response = try await transport.stream(URLRequest(url: try #require(URL(string: "https://api.example.com"))))

    var events: [ServerSentEvent] = []
    let error = await #expect(throws: URLError.self) {
      for try await event in response.body.serverSentEvents() { events.append(event) }
    }

    #expect(events == [ServerSentEvent(data: "a")])
    #expect(error?.code == .networkConnectionLost)
  }

  @Test("should answer through the handler and record each request")
  func answersThroughHandler() async throws {
    let transport = StubHTTPStreamingTransport { request in
      let status = request.url?.path() == "/limited" ? 429 : 200
      return try StubHTTPStreamingTransport.response(to: request, status: status, headers: ["Retry-After": "5"], steps: [])
    }
    let limited = URLRequest(url: try #require(URL(string: "https://api.example.com/limited")))
    let open = URLRequest(url: try #require(URL(string: "https://api.example.com/open")))

    let first = try await transport.stream(limited)
    let second = try await transport.stream(open)

    #expect(first.response.statusCode == 429)
    #expect(second.response.statusCode == 200)
    #expect(transport.requests.map(\.url) == [limited.url, open.url])
  }
}
