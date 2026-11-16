import Foundation

import ShadowCore

public struct SegmentHeader: Sendable, Equatable {
  public let replica: ReplicaID
  public let first: Int64
  public let last: Int64
  public let previous: StreamPoint?
  public let dependencies: [ReplicaID: StreamPoint]
  public let schema: Int

  public init?(replica: ReplicaID, first: Int64, last: Int64, previous: StreamPoint?, dependencies: [ReplicaID: StreamPoint], schema: Int) {
    guard first >= 1, first <= last, last <= VaultPath.maximumSequence, schema >= 0 else { return nil }
    guard Self.isValid(previous: previous, first: first) else { return nil }
    guard dependencies[replica] == nil, dependencies.values.allSatisfy(\.isOnStream) else { return nil }
    self.replica = replica
    self.first = first
    self.last = last
    self.previous = previous
    self.dependencies = dependencies
    self.schema = schema
  }

  var lineCount: Int64 { last - first + 1 }

  private static func isValid(previous: StreamPoint?, first: Int64) -> Bool {
    guard let previous else { return first == 1 }
    return previous.isOnStream && previous.last == first - 1
  }
}

public struct SegmentFile: Sendable, Equatable {
  public let header: SegmentHeader
  public let lines: [Data]

  public init?(header: SegmentHeader, lines: [Data]) {
    self.init(header: header, lines: lines, lineLimit: CodecFrame.maximumLineCount)
  }

  init?(header: SegmentHeader, lines: [Data], lineLimit: Int) {
    guard lines.count <= lineLimit, Int64(lines.count) == header.lineCount, lines.allSatisfy(CodecFrame.isValidLine) else { return nil }
    self.header = header
    self.lines = lines
  }
}

public struct SealedFile: Sendable, Equatable {
  public let key: ObjectKey
  public let tag: ContentTag
  public let data: Data
}

public enum SegmentCodec {
  public static let maximumPayloadBytes = 64 * 1024 * 1024
  public static let maximumLineCount = CodecFrame.maximumLineCount
  static let kind = "segment"
  static let members: Set<String> = ["count", "deps", "first", "format", "kind", "last", "prev", "replica", "schema"]

  public static func payload(of file: SegmentFile) -> Data {
    CodecFrame.payload(header: headerValue(file.header), lines: file.lines)
  }

  public static func seal(_ file: SegmentFile, vault: VaultID, with key: VaultKey) throws(VaultCodecError) -> SealedFile {
    let payload = payload(of: file)
    guard payload.count <= maximumPayloadBytes else { throw .payloadTooLarge }
    let tag = ContentTag.make(for: payload, key: key)
    let objectKey = VaultPath.segment(file.header.replica, first: file.header.first, last: file.header.last, tag: tag)
    return SealedFile(key: objectKey, tag: tag, data: try CodecFrame.seal(payload, at: objectKey, vault: vault, with: key))
  }

  public static func open(_ data: Data, at key: ObjectKey, vault: VaultID, keys: (KeyID) -> VaultKey?) throws(VaultCodecError) -> SegmentFile {
    try open(data, at: key, vault: vault, keys: keys, payloadLimit: maximumPayloadBytes, lineLimit: maximumLineCount)
  }

  static func open(
    _ data: Data,
    at key: ObjectKey,
    vault: VaultID,
    keys: (KeyID) -> VaultKey?,
    payloadLimit: Int,
    lineLimit: Int = maximumLineCount
  ) throws(VaultCodecError) -> SegmentFile {
    guard case .segment(let replica, let first, let last, let tag) = VaultPath.classify(key) else { throw .pathMismatch }
    let (payload, openingKey) = try CodecFrame.open(data, at: key, vault: vault, keys: keys, limit: payloadLimit)
    let file = try parse(payload, lineLimit: lineLimit)
    guard file.header.replica == replica, file.header.first == first, file.header.last == last else { throw .pathMismatch }
    guard ContentTag.make(for: payload, key: openingKey) == tag else { throw .tagMismatch }
    return file
  }

  static func parse(_ payload: Data, lineLimit: Int) throws(VaultCodecError) -> SegmentFile {
    let (line, linesStart) = try CodecFrame.headerLine(of: payload)
    let fields = try CodecFields(line: line, kind: kind, members: members)
    let header = SegmentHeader(
      replica: try fields.replica("replica"),
      first: try fields.int("first"),
      last: try fields.int("last"),
      previous: try fields.point("prev"),
      dependencies: try fields.points("deps"),
      schema: try fields.count("schema")
    )
    guard let header else { throw .malformed("segment header breaks a header rule") }
    let count = try fields.count("count")
    guard Int64(count) == header.lineCount else { throw .malformed("count does not match first and last") }
    guard count <= lineLimit else { throw .malformed("more lines than a file may hold") }
    let lines = try CodecFrame.lines(of: payload, from: linesStart, limit: count)
    guard let file = SegmentFile(header: header, lines: lines, lineLimit: lineLimit) else { throw .malformed("fewer lines than counted") }
    return file
  }

  private static func headerValue(_ header: SegmentHeader) -> JSONValue {
    .object([
      "count": .int(header.lineCount),
      "deps": .object(Dictionary(uniqueKeysWithValues: header.dependencies.map { ($0.key.description, CodecFrame.pointValue($0.value)) })),
      "first": .int(header.first),
      "format": .int(CodecFrame.format),
      "kind": .string(kind),
      "last": .int(header.last),
      "prev": header.previous.map(CodecFrame.pointValue) ?? .null,
      "replica": .string(header.replica.description),
      "schema": .int(Int64(header.schema)),
    ])
  }
}
