import Foundation

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

public struct ServerSentEventParser: Sendable {
  private var line: [UInt8] = []
  private var skipsLineFeed = false
  private var isAtStreamStart = true
  private var eventType = ""
  private var dataBuffer = ""
  private var lastEventID = ""
  private var reconnectionTime: Int?

  public init() {}

  public mutating func consume(_ chunk: Data) -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    for byte in chunk {
      if skipsLineFeed {
        skipsLineFeed = false
        if byte == lineFeed { continue }
      }
      switch byte {
      case lineFeed:
        if let event = completeLine() { events.append(event) }
      case carriageReturn:
        skipsLineFeed = true
        if let event = completeLine() { events.append(event) }
      default:
        line.append(byte)
      }
    }
    return events
  }

  public mutating func finish() -> [ServerSentEvent] {
    self = ServerSentEventParser()
    return []
  }

  private mutating func completeLine() -> ServerSentEvent? {
    defer { line.removeAll(keepingCapacity: true) }
    if isAtStreamStart {
      isAtStreamStart = false
      if line.starts(with: byteOrderMark) { line.removeFirst(byteOrderMark.count) }
    }

    guard let first = line.first else { return dispatch() }
    guard first != colon else { return nil }

    guard let separator = line.firstIndex(of: colon) else {
      process(field: line[...], value: ArraySlice())
      return nil
    }
    var valueStart = line.index(after: separator)
    if valueStart < line.endIndex, line[valueStart] == space { valueStart = line.index(after: valueStart) }
    process(field: line[..<separator], value: line[valueStart...])
    return nil
  }

  private mutating func process(field: ArraySlice<UInt8>, value: ArraySlice<UInt8>) {
    switch String(decoding: field, as: UTF8.self) {
    case "event":
      eventType = String(decoding: value, as: UTF8.self)
    case "data":
      dataBuffer += String(decoding: value, as: UTF8.self)
      dataBuffer += "\n"
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
      eventType = ""
    }
    guard !dataBuffer.isEmpty else { return nil }
    dataBuffer.unicodeScalars.removeLast()
    return ServerSentEvent(event: eventType.isEmpty ? nil : eventType, data: dataBuffer, id: lastEventID.isEmpty ? nil : lastEventID, retry: reconnectionTime)
  }
}

extension AsyncSequence where Element == Data, Self: Sendable {
  public func serverSentEvents() -> AsyncThrowingStream<ServerSentEvent, any Error> {
    let (events, continuation) = AsyncThrowingStream<ServerSentEvent, any Error>.makeStream()
    let pump = Task {
      var parser = ServerSentEventParser()
      do {
        for try await chunk in self {
          for event in parser.consume(chunk) { continuation.yield(event) }
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
