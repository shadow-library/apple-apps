import Foundation
import ShadowCore

private let lineFeed = UInt8(ascii: "\n")
private let carriageReturn = UInt8(ascii: "\r")
private let colon = UInt8(ascii: ":")
private let space = UInt8(ascii: " ")
private let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

public struct ServerSentEvent: Sendable, Equatable {
  public var event: String?
  public var data: String
  public var id: String?
  public var retry: Int?

  public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
    self.event = event
    self.data = data
    self.id = id
    self.retry = retry
  }
}

public enum ServerSentEventError: ShadowError, Equatable {
  case lineTooLong(limit: Int)
  case eventTooLarge(limit: Int)

  public var code: String {
    switch self {
    case .lineTooLong: "network.sse_line_too_long"
    case .eventTooLarge: "network.sse_event_too_large"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .lineTooLong(let limit): "A server-sent event line is longer than \(limit) bytes."
    case .eventTooLarge(let limit): "A server-sent event holds more than \(limit) bytes of data."
    }
  }
}

public struct ServerSentEventParser: Sendable {
  public let maximumLineBytes: Int
  public let maximumEventBytes: Int
  public private(set) var failure: ServerSentEventError?

  private var line: [UInt8] = []
  private var skipsLineFeed = false
  private var isAtStreamStart = true
  private var eventType = ""
  private var dataBuffer = ""
  private var hasData = false
  private var lastEventID = ""
  private var reconnectionTime: Int?

  package var retainedBytes: Int { line.count + dataBuffer.utf8.count }

  public init(maximumLineBytes: Int = 1 << 20, maximumEventBytes: Int = 8 << 20) {
    self.maximumLineBytes = maximumLineBytes
    self.maximumEventBytes = maximumEventBytes
  }

  /// Events completed before an overflow in the same chunk are returned; the error is thrown by the next call, and `failure` is set meanwhile.
  public mutating func parse(_ chunk: Data) throws(ServerSentEventError) -> [ServerSentEvent] {
    if let failure { throw failure }
    var events: [ServerSentEvent] = []
    do {
      for byte in chunk {
        if let event = try advance(byte) { events.append(event) }
      }
    } catch {
      failure = error
      line = []
      dataBuffer = ""
      guard !events.isEmpty else { throw error }
    }
    return events
  }

  /// New code uses `parse`, which reports an oversized line or event instead of silently ending the stream.
  public mutating func consume(_ chunk: Data) -> [ServerSentEvent] {
    (try? parse(chunk)) ?? []
  }

  public mutating func finish() -> [ServerSentEvent] {
    guard failure == nil else { return [] }
    self = ServerSentEventParser(maximumLineBytes: maximumLineBytes, maximumEventBytes: maximumEventBytes)
    return []
  }

  private mutating func advance(_ byte: UInt8) throws(ServerSentEventError) -> ServerSentEvent? {
    if skipsLineFeed {
      skipsLineFeed = false
      if byte == lineFeed { return nil }
    }
    switch byte {
    case lineFeed:
      return try completeLine()
    case carriageReturn:
      skipsLineFeed = true
      return try completeLine()
    default:
      guard line.count < maximumLineBytes else { throw .lineTooLong(limit: maximumLineBytes) }
      line.append(byte)
      return nil
    }
  }

  private mutating func completeLine() throws(ServerSentEventError) -> ServerSentEvent? {
    defer { line.removeAll(keepingCapacity: true) }
    if isAtStreamStart {
      isAtStreamStart = false
      if line.starts(with: byteOrderMark) { line.removeFirst(byteOrderMark.count) }
    }

    guard let first = line.first else { return dispatch() }
    guard first != colon else { return nil }

    guard let separator = line.firstIndex(of: colon) else {
      try process(field: line[...], value: ArraySlice())
      return nil
    }
    var valueStart = line.index(after: separator)
    if valueStart < line.endIndex, line[valueStart] == space { valueStart = line.index(after: valueStart) }
    try process(field: line[..<separator], value: line[valueStart...])
    return nil
  }

  private mutating func process(field: ArraySlice<UInt8>, value: ArraySlice<UInt8>) throws(ServerSentEventError) {
    switch String(decoding: field, as: UTF8.self) {
    case "event":
      eventType = String(decoding: value, as: UTF8.self)
    case "data":
      let text = String(decoding: value, as: UTF8.self)
      let separator = hasData ? 1 : 0
      guard dataBuffer.utf8.count + separator + text.utf8.count <= maximumEventBytes else { throw .eventTooLarge(limit: maximumEventBytes) }
      if hasData { dataBuffer += "\n" }
      dataBuffer += text
      hasData = true
    case "id":
      guard !value.contains(0) else { return }
      lastEventID = String(decoding: value, as: UTF8.self)
    case "retry":
      guard !value.isEmpty, value.allSatisfy({ (0x30...0x39).contains($0) }), let milliseconds = Int(String(decoding: value, as: UTF8.self)) else { return }
      reconnectionTime = milliseconds
    default:
      return
    }
  }

  private mutating func dispatch() -> ServerSentEvent? {
    defer {
      dataBuffer = ""
      hasData = false
      eventType = ""
    }
    guard hasData else { return nil }
    return ServerSentEvent(event: eventType.isEmpty ? nil : eventType, data: dataBuffer, id: lastEventID.isEmpty ? nil : lastEventID, retry: reconnectionTime)
  }
}

extension AsyncSequence where Element == Data, Self: Sendable {
  public func serverSentEvents(maximumLineBytes: Int = 1 << 20, maximumEventBytes: Int = 8 << 20) -> AsyncThrowingStream<ServerSentEvent, any Error> {
    let (events, continuation) = AsyncThrowingStream<ServerSentEvent, any Error>.makeStream()
    let pump = Task {
      var parser = ServerSentEventParser(maximumLineBytes: maximumLineBytes, maximumEventBytes: maximumEventBytes)
      do {
        for try await chunk in self {
          for event in try parser.parse(chunk) { continuation.yield(event) }
          if let failure = parser.failure { throw failure }
        }
        for event in parser.finish() { continuation.yield(event) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in pump.cancel() }
    return events
  }
}
