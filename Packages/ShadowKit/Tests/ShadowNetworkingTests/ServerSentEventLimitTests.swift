import Foundation
import ShadowNetworking
import ShadowTestSupport
import Synchronization
import Testing

private struct Outcome: Equatable {
  var events: [ServerSentEvent] = []
  var error: ServerSentEventError?
}

private func run(_ chunks: [Data], maximumLineBytes: Int = 1 << 20, maximumEventBytes: Int = 8 << 20) -> Outcome {
  var parser = ServerSentEventParser(maximumLineBytes: maximumLineBytes, maximumEventBytes: maximumEventBytes)
  var outcome = Outcome()
  for chunk in chunks {
    do {
      outcome.events += try parser.parse(chunk)
    } catch {
      outcome.error = error
      return outcome
    }
    if let failure = parser.failure {
      outcome.error = failure
      return outcome
    }
  }
  return outcome
}

private func run(_ text: String, maximumLineBytes: Int = 1 << 20, maximumEventBytes: Int = 8 << 20) -> Outcome {
  run([Data(text.utf8)], maximumLineBytes: maximumLineBytes, maximumEventBytes: maximumEventBytes)
}

private func split(_ data: Data, every size: Int) -> [Data] {
  stride(from: 0, to: data.count, by: size).map { Data(data[$0..<min($0 + size, data.count)]) }
}

@Suite("ServerSentEventParser limits")
struct ServerSentEventLimitTests {
  @Test("should accept a line of exactly the limit and refuse one byte more")
  func enforcesLineLimit() {
    let exact = "data: " + String(repeating: "a", count: 10)

    #expect(run(exact + "\n\n", maximumLineBytes: 16) == Outcome(events: [ServerSentEvent(data: String(repeating: "a", count: 10))]))
    #expect(run(exact + "a\n\n", maximumLineBytes: 16) == Outcome(error: .lineTooLong(limit: 16)))
  }

  @Test("should not count the line terminator", arguments: ["\n", "\r", "\r\n"])
  func ignoresTerminator(terminator: String) {
    let line = "data: " + String(repeating: "a", count: 10)

    #expect(run(line + terminator + terminator, maximumLineBytes: 16).error == nil)
  }

  @Test("should refuse an oversized line that has no terminator yet")
  func refusesUnterminatedLine() {
    #expect(run(String(repeating: "x", count: 17), maximumLineBytes: 16) == Outcome(error: .lineTooLong(limit: 16)))
  }

  @Test("should reach the same outcome for every chunk size when the stream fits")
  func acceptsAtEveryChunkSize() {
    let stream = Data("event: e\ndata: 0123456789\nid: 7\n\n: keep-alive\r\ndata: tail\r\r".utf8)
    let expected = run([stream], maximumLineBytes: 16)

    #expect(expected.error == nil)
    #expect(expected.events.count == 2)
    for size in 1...stream.count { #expect(run(split(stream, every: size), maximumLineBytes: 16) == expected, "chunk size \(size)") }
  }

  @Test("should reach the same outcome for every chunk size when a line overflows")
  func refusesAtEveryChunkSize() {
    let stream = Data("data: ok\n\ndata: fine\n\ndata: 0123456789ABCDEF\n\ndata: never\n\n".utf8)
    let expected = Outcome(events: [ServerSentEvent(data: "ok"), ServerSentEvent(data: "fine")], error: .lineTooLong(limit: 16))

    #expect(run([stream], maximumLineBytes: 16) == expected)
    for size in 1...stream.count { #expect(run(split(stream, every: size), maximumLineBytes: 16) == expected, "chunk size \(size)") }
  }

  @Test("should reach the same outcome for any random chunking of a random stream")
  func agreesUnderRandomChunking() throws {
    let fragments = ["data: abc\n", "\n", "event: x\r\n", ":c\n", "\r", "data\n", "id: 4\n", "retry: 20\n", "data: " + String(repeating: "z", count: 30) + "\n", "data: é🌍\n"]
    try forAll { generator in
      let text = (0..<generator.int(in: 1...25)).map { _ in generator.pick(from: fragments) }.joined()
      let bytes = Data(text.utf8)
      var chunks: [Data] = []
      var offset = 0
      while offset < bytes.count {
        let end = min(offset + generator.int(in: 1...12), bytes.count)
        chunks.append(Data(bytes[offset..<end]))
        offset = end
      }

      #expect(run(chunks, maximumLineBytes: 24, maximumEventBytes: 40) == run([bytes], maximumLineBytes: 24, maximumEventBytes: 40))
    }
  }

  @Test("should bound the data of one event across its lines")
  func enforcesEventLimit() {
    let lines = "data: abcde\ndata: fghij\n\n"

    #expect(run(lines, maximumEventBytes: 11) == Outcome(events: [ServerSentEvent(data: "abcde\nfghij")]))
    #expect(run(lines, maximumEventBytes: 10) == Outcome(error: .eventTooLarge(limit: 10)))
  }

  @Test("should count empty data lines toward the event limit")
  func countsSeparators() {
    #expect(run("data\ndata\ndata\n\n", maximumEventBytes: 2) == Outcome(events: [ServerSentEvent(data: "\n\n")]))
    #expect(run("data\ndata\ndata\ndata\n\n", maximumEventBytes: 2) == Outcome(error: .eventTooLarge(limit: 2)))
  }

  @Test("should count the decoded size of invalid UTF-8 toward the event limit")
  func countsDecodedBytes() {
    let chunk = Data("data: ".utf8) + Data([0xFF, 0xFF]) + Data("\n\n".utf8)

    #expect(run([chunk], maximumEventBytes: 6).events == [ServerSentEvent(data: "\u{FFFD}\u{FFFD}")])
    #expect(run([chunk], maximumEventBytes: 5).error == .eventTooLarge(limit: 5))
  }

  @Test("should start counting a new event from zero after a dispatch")
  func resetsEventCount() {
    #expect(run("data: abcde\n\ndata: abcde\n\ndata: abcde\n\n", maximumEventBytes: 5).events.count == 3)
  }

  @Test("should deliver the events completed before an overflow in the same chunk and fail on the next call")
  func deliversEventsBeforeOverflow() throws {
    var parser = ServerSentEventParser(maximumLineBytes: 16)

    let events = try parser.parse(Data("data: a\n\ndata: b\n\n".utf8) + Data(String(repeating: "x", count: 17).utf8))

    #expect(events == [ServerSentEvent(data: "a"), ServerSentEvent(data: "b")])
    #expect(parser.failure == .lineTooLong(limit: 16))
    #expect(throws: ServerSentEventError.lineTooLong(limit: 16)) { try parser.parse(Data("data: c\n\n".utf8)) }
  }

  @Test("should throw at once when no event completed before the overflow")
  func throwsWithoutEarlierEvents() {
    var parser = ServerSentEventParser(maximumLineBytes: 16)

    #expect(throws: ServerSentEventError.lineTooLong(limit: 16)) { try parser.parse(Data(String(repeating: "x", count: 17).utf8)) }
  }

  @Test("should throw the same error from every later call once failed")
  func staysFailed() {
    var parser = ServerSentEventParser(maximumLineBytes: 4, maximumEventBytes: 4)
    #expect(throws: ServerSentEventError.lineTooLong(limit: 4)) { try parser.parse(Data("abcde".utf8)) }

    for chunk in ["", "\n", "data: a\n\n", "abcdefgh"] {
      #expect(throws: ServerSentEventError.lineTooLong(limit: 4)) { try parser.parse(Data(chunk.utf8)) }
      #expect(parser.consume(Data(chunk.utf8)).isEmpty)
    }
    #expect(parser.finish().isEmpty)
    #expect(throws: ServerSentEventError.lineTooLong(limit: 4)) { try parser.parse(Data("data: a\n\n".utf8)) }
  }

  @Test("should keep the first error when an event overflows")
  func keepsEventError() {
    var parser = ServerSentEventParser(maximumLineBytes: 100, maximumEventBytes: 3)
    #expect(throws: ServerSentEventError.eventTooLarge(limit: 3)) { try parser.parse(Data("data: abcd\n".utf8)) }

    #expect(throws: ServerSentEventError.eventTooLarge(limit: 3)) { try parser.parse(Data(String(repeating: "x", count: 200).utf8)) }
  }

  @Test("should drop what it held when it fails")
  func releasesMemoryOnFailure() {
    var parser = ServerSentEventParser(maximumLineBytes: 16, maximumEventBytes: 64)
    _ = parser.consume(Data("data: held\n".utf8))
    #expect(parser.retainedBytes > 0)

    _ = parser.consume(Data(String(repeating: "x", count: 17).utf8))

    #expect(parser.retainedBytes == 0)
  }

  @Test("should keep consume compatible and return nothing further after an overflow")
  func keepsConsumeCompatible() {
    var parser = ServerSentEventParser(maximumLineBytes: 16)

    #expect(parser.consume(Data("data: a\n\n".utf8)) == [ServerSentEvent(data: "a")])
    #expect(parser.consume(Data("data: b\n\n".utf8) + Data(String(repeating: "x", count: 17).utf8)) == [ServerSentEvent(data: "b")])
    #expect(parser.consume(Data("data: c\n\n".utf8)).isEmpty)
  }

  @Test("should reset between streams with finish and keep its limits")
  func finishKeepsLimits() {
    var parser = ServerSentEventParser(maximumLineBytes: 16)
    _ = parser.consume(Data("data: partial".utf8))
    _ = parser.finish()

    #expect(parser.maximumLineBytes == 16)
    #expect(parser.retainedBytes == 0)
    #expect(throws: ServerSentEventError.lineTooLong(limit: 16)) { try parser.parse(Data(String(repeating: "x", count: 17).utf8)) }
  }

  @Test("should default to a 1 MiB line and an 8 MiB event")
  func hasDefaults() {
    let parser = ServerSentEventParser()

    #expect(parser.maximumLineBytes == 1_048_576)
    #expect(parser.maximumEventBytes == 8_388_608)
  }

  @Test("should never hold more than its limits while 64 MiB of one endless line arrives")
  func boundsMemoryOnEndlessLine() {
    let limit = 1 << 20
    let chunk = Data(repeating: UInt8(ascii: "a"), count: 16 << 10)
    var parser = ServerSentEventParser(maximumLineBytes: limit)
    var fed = 0
    var thrown: ServerSentEventError?

    while fed < (64 << 20) / chunk.count {
      do {
        _ = try parser.parse(chunk)
      } catch {
        thrown = error
        break
      }
      fed += 1
      #expect(parser.retainedBytes <= limit)
    }

    #expect(thrown == .lineTooLong(limit: limit))
    #expect(fed == limit / chunk.count)
    #expect(parser.retainedBytes == 0)
  }

  @Test("should never hold more than its limits while 64 MiB of one endless event arrives")
  func boundsMemoryOnEndlessEvent() {
    let limit = 1 << 20
    let chunk = Data(String(repeating: "data: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", count: 256).utf8)
    var parser = ServerSentEventParser(maximumLineBytes: limit, maximumEventBytes: limit)
    var thrown: ServerSentEventError?
    var fed = 0

    while fed < (64 << 20) / chunk.count, thrown == nil {
      do {
        _ = try parser.parse(chunk)
      } catch {
        thrown = error
      }
      fed += 1
      #expect(parser.retainedBytes <= 2 * limit)
    }

    #expect(thrown == .eventTooLarge(limit: limit))
    #expect(fed < 80)
    #expect(parser.retainedBytes == 0)
  }

  @Test("should throw the typed error from serverSentEvents after the events before it, and stop reading")
  func surfacesErrorFromSequence() async throws {
    let pulled = Mutex(0)
    let chunks = AsyncThrowingStream<Data, any Error>(unfolding: {
      let index = pulled.withLock { count in
        count += 1
        return count
      }
      guard index <= 1_000 else { return nil }
      return index == 1 ? Data("data: first\n\n".utf8) : Data(repeating: UInt8(ascii: "a"), count: 1_024)
    })
    var events: [ServerSentEvent] = []

    let error = await #expect(throws: ServerSentEventError.self) {
      for try await event in chunks.serverSentEvents(maximumLineBytes: 4_096) { events.append(event) }
    }

    #expect(error == .lineTooLong(limit: 4_096))
    #expect(events == [ServerSentEvent(data: "first")])
    #expect(pulled.withLock { $0 } < 10)
  }

  @Test("should throw the typed error from serverSentEvents when the overflow is in the first chunk")
  func surfacesErrorFromFirstChunk() async throws {
    let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    continuation.yield(Data(repeating: UInt8(ascii: "a"), count: 100))

    let error = await #expect(throws: ServerSentEventError.self) {
      for try await _ in chunks.serverSentEvents(maximumLineBytes: 10) {}
    }

    #expect(error == .lineTooLong(limit: 10))
  }
}
