import Foundation
import ShadowNetworking
import Testing

private let realisticStream = Data(
  [
    "\u{FEFF}: OPENROUTER PROCESSING\r\n\r\n",
    "event: message_start\r\ndata: {\"type\":\"message_start\"}\r\n\r\n",
    "event: content_block_delta\nid: 7\ndata: {\"text\":\"héllo 🌍\"}\n\n",
    ":\n\n",
    "retry: 1500\rdata: line one\rdata: line two\r\r",
    "data: [DONE]\n\n",
    "data: unterminated\n",
  ].joined().utf8
)

private let realisticEvents = [
  ServerSentEvent(event: "message_start", data: #"{"type":"message_start"}"#),
  ServerSentEvent(event: "content_block_delta", data: #"{"text":"héllo 🌍"}"#, id: "7"),
  ServerSentEvent(data: "line one\nline two", id: "7", retry: 1500),
  ServerSentEvent(data: "[DONE]", id: "7", retry: 1500),
]

private func parse(_ chunks: [Data]) -> [ServerSentEvent] {
  var parser = ServerSentEventParser()
  return chunks.flatMap { parser.consume($0) } + parser.finish()
}

private func parse(_ text: String) -> [ServerSentEvent] {
  parse([Data(text.utf8)])
}

@Suite("ServerSentEventParser")
struct ServerSentEventParserTests {
  @Test("should join multiple data lines with line feeds")
  func joinsDataLines() {
    #expect(parse("data: YHOO\ndata: +2\ndata: 10\n\n") == [ServerSentEvent(data: "YHOO\n+2\n10")])
  }

  @Test("should follow the specification's comment and id example")
  func followsCommentAndIDExample() {
    let stream = ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n"

    #expect(parse(stream) == [ServerSentEvent(data: "first event", id: "1"), ServerSentEvent(data: "second event"), ServerSentEvent(data: " third event")])
  }

  @Test("should dispatch empty data and discard a block without a trailing blank line")
  func dispatchesEmptyData() {
    #expect(parse("data\n\ndata\ndata\n\ndata:") == [ServerSentEvent(data: ""), ServerSentEvent(data: "\n")])
  }

  @Test("should remove only one leading space from a value")
  func removesOneLeadingSpace() {
    #expect(parse("data:test\n\ndata: test\n\n") == [ServerSentEvent(data: "test"), ServerSentEvent(data: "test")])
  }

  @Test("should carry the event type and reset it after each dispatch")
  func carriesEventType() {
    let stream = "event: add\ndata: 73857293\n\nevent: remove\ndata: 2153\n\nevent: add\ndata: 113411\n\ndata: plain\n\n"

    #expect(
      parse(stream) == [
        ServerSentEvent(event: "add", data: "73857293"),
        ServerSentEvent(event: "remove", data: "2153"),
        ServerSentEvent(event: "add", data: "113411"),
        ServerSentEvent(data: "plain"),
      ]
    )
  }

  @Test("should reset the event type when a block has no data")
  func resetsEventTypeWithoutData() {
    #expect(parse("event: ping\n\ndata: x\n\n") == [ServerSentEvent(data: "x")])
  }

  @Test("should ignore comments and keep-alive lines")
  func ignoresComments() {
    #expect(parse(": OPENROUTER PROCESSING\n\n:\n\n: ping\ndata: x\n: between\n\n") == [ServerSentEvent(data: "x")])
  }

  @Test("should ignore unknown fields")
  func ignoresUnknownFields() {
    #expect(parse("foo: bar\nData: shouted\ndata: x\nevent\n\n") == [ServerSentEvent(data: "x")])
  }

  @Test("should accept CRLF, CR and LF line endings")
  func acceptsLineEndings() {
    let expected = [ServerSentEvent(event: "e", data: "a\nb")]

    #expect(parse("event: e\r\ndata: a\r\ndata: b\r\n\r\n") == expected)
    #expect(parse("event: e\rdata: a\rdata: b\r\r") == expected)
    #expect(parse("event: e\ndata: a\ndata: b\n\n") == expected)
    #expect(parse("event: e\r\ndata: a\rdata: b\n\r\n") == expected)
  }

  @Test("should treat a CR at the end of one chunk and an LF at the start of the next as one line break")
  func joinsCRLFAcrossChunks() {
    #expect(parse([Data("data: a\r".utf8), Data("\ndata: b\r".utf8), Data("\n\r".utf8), Data("\n".utf8)]) == [ServerSentEvent(data: "a\nb")])
  }

  @Test("should strip one leading byte order mark")
  func stripsByteOrderMark() {
    #expect(parse("\u{FEFF}data: x\n\n") == [ServerSentEvent(data: "x")])
    #expect(parse([Data([0xEF]), Data([0xBB]), Data([0xBF]) + Data("data: x\n\n".utf8)]) == [ServerSentEvent(data: "x")])
    #expect(parse("\u{FEFF}\u{FEFF}data: x\n\n").isEmpty)
    #expect(parse("data: x\n\n\u{FEFF}data: y\n\n") == [ServerSentEvent(data: "x")])
  }

  @Test("should keep the last event id across events and ignore ids containing NUL")
  func appliesIDRules() {
    let stream = "id: 1\ndata: a\n\ndata: b\n\nid: 2\u{0}x\ndata: c\n\nid:\ndata: d\n\n"

    #expect(parse(stream) == [ServerSentEvent(data: "a", id: "1"), ServerSentEvent(data: "b", id: "1"), ServerSentEvent(data: "c", id: "1"), ServerSentEvent(data: "d")])
  }

  @Test("should accept retry only when it is made of ASCII digits")
  func appliesRetryRules() {
    #expect(parse("retry: 3000\ndata: a\n\n") == [ServerSentEvent(data: "a", retry: 3000)])
    #expect(parse("retry: 30a0\ndata: a\n\n") == [ServerSentEvent(data: "a")])
    #expect(parse("retry: -1\ndata: a\n\n") == [ServerSentEvent(data: "a")])
    #expect(parse("retry: +1\ndata: a\n\n") == [ServerSentEvent(data: "a")])
    #expect(parse("retry:  3000\ndata: a\n\n") == [ServerSentEvent(data: "a")])
    #expect(parse("retry:\ndata: a\n\n") == [ServerSentEvent(data: "a")])
    #expect(parse("retry: 1000\n\nretry: 2000\nretry: x\ndata: a\n\n") == [ServerSentEvent(data: "a", retry: 2000)])
  }

  @Test("should discard an unterminated final event")
  func discardsUnterminatedEvent() {
    var parser = ServerSentEventParser()

    #expect(parser.consume(Data("data: complete\n\ndata: partial\n".utf8)) == [ServerSentEvent(data: "complete")])
    #expect(parser.finish().isEmpty)
    #expect(parser.consume(Data("\n".utf8)).isEmpty)
  }

  @Test("should decode a multi-byte character split across chunks")
  func decodesSplitCharacters() {
    let bytes = Data("data: é🌍\n\n".utf8)

    #expect(parse([bytes[..<7], bytes[7..<10], bytes[10...]]) == [ServerSentEvent(data: "é🌍")])
  }

  @Test("should replace invalid UTF-8 with the replacement character")
  func replacesInvalidUTF8() {
    #expect(parse([Data("data: a".utf8) + Data([0xFF, 0xC3]) + Data("\n\n".utf8)]) == [ServerSentEvent(data: "a\u{FFFD}\u{FFFD}")])
  }

  @Test("should parse a realistic stream fed whole")
  func parsesRealisticStream() {
    #expect(parse([realisticStream]) == realisticEvents)
  }

  @Test("should produce the same events however the stream is split in two")
  func parsesEveryTwoWaySplit() {
    for offset in 0...realisticStream.count {
      let index = realisticStream.startIndex + offset
      let events = parse([realisticStream[..<index], realisticStream[index...]])
      #expect(events == realisticEvents, "split at byte \(offset)")
    }
  }

  @Test("should produce the same events when the stream arrives one byte at a time")
  func parsesByteByByte() {
    #expect(parse(realisticStream.map { Data([$0]) }) == realisticEvents)
  }

  @Test("should parse events from an asynchronous byte stream")
  func parsesAsyncSequence() async throws {
    let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    for offset in stride(from: 0, to: realisticStream.count, by: 5) {
      continuation.yield(Data(realisticStream[offset..<min(offset + 5, realisticStream.count)]))
    }
    continuation.finish()

    var events: [ServerSentEvent] = []
    for try await event in chunks.serverSentEvents() { events.append(event) }

    #expect(events == realisticEvents)
  }

  @Test("should rethrow the byte stream's failure after the events before it")
  func rethrowsFailure() async throws {
    let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(Data("data: a\n\ndata: b\n".utf8))
    continuation.finish(throwing: URLError(.networkConnectionLost))

    var events: [ServerSentEvent] = []
    let error = await #expect(throws: URLError.self) {
      for try await event in chunks.serverSentEvents() { events.append(event) }
    }

    #expect(events == [ServerSentEvent(data: "a")])
    #expect(error?.code == .networkConnectionLost)
  }
}
