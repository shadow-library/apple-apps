import Foundation

import ShadowCore

public struct BaseHeader: Sendable, Equatable {
  public let replica: ReplicaID
  public let upTo: Int64
  public let through: StreamPoint?
  public let schema: Int

  public init?(replica: ReplicaID, upTo: Int64, through: StreamPoint?, schema: Int) {
    guard upTo >= 0, upTo <= VaultPath.maximumSequence, schema >= 0 else { return nil }
    if let through { guard through.isOnStream, through.last <= upTo else { return nil } }
    self.replica = replica
    self.upTo = upTo
    self.through = through
    self.schema = schema
  }
}

public struct BaseFile: Sendable, Equatable {
  public let header: BaseHeader
  public let lines: [Data]

  public init?(header: BaseHeader, lines: [Data]) {
    guard lines.allSatisfy(CodecFrame.isValidLine) else { return nil }
    self.header = header
    self.lines = lines
  }
}

public struct BasePart: Sendable, Equatable {
  public let header: BaseHeader
  public let tag: ContentTag
  public let keyID: KeyID
  public let part: Int
  public let parts: Int
  public let totalLines: Int
  public let lines: [Data]
}

public enum BaseCodec {
  public static let defaultPartPayloadBytes = 15 * 1024 * 1024
  public static let maximumPartPayloadBytes = 32 * 1024 * 1024
  public static let maximumLineCount = CodecFrame.maximumLineCount
  static let kind = "base"
  static let logicalMembers: Set<String> = ["format", "kind", "lines", "replica", "schema", "through", "upto"]
  static let partMembers = logicalMembers.union(["count", "part", "parts"])

  public static func seal(
    _ file: BaseFile,
    vault: VaultID,
    with key: VaultKey,
    partPayloadBytes: Int = defaultPartPayloadBytes
  ) throws(VaultCodecError) -> [SealedFile] {
    let payloads = try partPayloads(of: file, partPayloadBytes: partPayloadBytes)
    let tag = logicalTag(header: file.header, lines: file.lines, key: key)
    var sealed: [SealedFile] = []
    for (index, payload) in payloads.enumerated() {
      let objectKey = VaultPath.basePart(file.header.replica, upTo: file.header.upTo, tag: tag, part: index + 1, parts: payloads.count)
      sealed.append(SealedFile(key: objectKey, tag: tag, data: try CodecFrame.seal(payload, at: objectKey, vault: vault, with: key)))
    }
    return sealed
  }

  public static func openPart(_ data: Data, at key: ObjectKey, vault: VaultID, keys: (KeyID) -> VaultKey?) throws(VaultCodecError) -> BasePart {
    try openPart(data, at: key, vault: vault, keys: keys, payloadLimit: maximumPartPayloadBytes, lineLimit: maximumLineCount)
  }

  public static func assemble(_ parts: [BasePart], keys: (KeyID) -> VaultKey?) throws(VaultCodecError) -> BaseFile {
    guard let reference = parts.first else { throw .incomplete(missing: []) }
    for part in parts {
      guard part.header == reference.header, part.tag == reference.tag else { throw .inconsistentParts("parts come from different bases") }
      guard part.keyID == reference.keyID else { throw .inconsistentParts("parts are sealed with different keys") }
      guard part.parts == reference.parts, part.totalLines == reference.totalLines else { throw .inconsistentParts("parts disagree on their totals") }
      guard VaultPath.isPart(part.part, of: part.parts) else { throw .inconsistentParts("part number out of range") }
    }
    var byNumber: [Int: BasePart] = [:]
    for part in parts {
      guard byNumber.updateValue(part, forKey: part.part) == nil else { throw .inconsistentParts("part \(part.part) appears twice") }
    }
    let missing = (1...reference.parts).filter { byNumber[$0] == nil }
    guard missing.isEmpty else { throw .incomplete(missing: missing) }
    let lines = (1...reference.parts).flatMap { byNumber[$0]?.lines ?? [] }
    guard lines.count == reference.totalLines else { throw .inconsistentParts("line counts do not add up to the total") }
    guard let key = keys(reference.keyID), key.id == reference.keyID else { throw .file(.keyUnavailable(reference.keyID)) }
    guard logicalTag(header: reference.header, lines: lines, key: key) == reference.tag else { throw .tagMismatch }
    guard let file = BaseFile(header: reference.header, lines: lines) else { throw .malformed("base line breaks a line rule") }
    return file
  }

  static func openPart(
    _ data: Data,
    at key: ObjectKey,
    vault: VaultID,
    keys: (KeyID) -> VaultKey?,
    payloadLimit: Int,
    lineLimit: Int = maximumLineCount
  ) throws(VaultCodecError) -> BasePart {
    guard case .basePart(let replica, let upTo, let tag, let part, let parts) = VaultPath.classify(key) else { throw .pathMismatch }
    let (payload, openingKey) = try CodecFrame.open(data, at: key, vault: vault, keys: keys, limit: payloadLimit)
    let (line, linesStart) = try CodecFrame.headerLine(of: payload)
    let fields = try CodecFields(line: line, kind: kind, members: partMembers)
    let header = BaseHeader(replica: try fields.replica("replica"), upTo: try fields.int("upto"), through: try fields.point("through"), schema: try fields.count("schema"))
    guard let header else { throw .malformed("base header breaks a header rule") }
    let count = try fields.count("count")
    let totalLines = try fields.count("lines")
    let headerPart = try fields.count("part")
    let headerParts = try fields.count("parts")
    guard VaultPath.isPart(headerPart, of: headerParts), count <= totalLines else { throw .malformed("part numbers or counts are out of range") }
    guard header.replica == replica, header.upTo == upTo, headerPart == part, headerParts == parts else { throw .pathMismatch }
    guard count <= lineLimit else { throw .malformed("more lines than a file may hold") }
    let lines = try CodecFrame.lines(of: payload, from: linesStart, limit: count)
    guard lines.count == count else { throw .malformed("fewer lines than counted") }
    return BasePart(header: header, tag: tag, keyID: openingKey.id, part: part, parts: parts, totalLines: totalLines, lines: lines)
  }

  static func partPayloads(of file: BaseFile, partPayloadBytes: Int, lineLimit: Int = maximumLineCount) throws(VaultCodecError) -> [Data] {
    guard partPayloadBytes >= 1, partPayloadBytes <= maximumPartPayloadBytes else { throw .invalidPartPayloadBytes(partPayloadBytes) }
    precondition(lineLimit >= 1, "a part holds at least one line")
    let ranges = try partition(file, limit: partPayloadBytes, lineLimit: lineLimit)
    return ranges.enumerated().map { index, range in
      let header = partHeaderValue(file.header, totalLines: file.lines.count, count: range.count, part: index + 1, parts: ranges.count)
      return CodecFrame.payload(header: header, lines: file.lines[range])
    }
  }

  private static func partition(_ file: BaseFile, limit: Int, lineLimit: Int) throws(VaultCodecError) -> [Range<Int>] {
    let zeroHeader = partHeaderValue(file.header, totalLines: file.lines.count, count: 0, part: 0, parts: 0)
    let layout = CodecPartLayout(fixedHeaderBytes: CanonicalJSON.encode(zeroHeader).count - 3 + 1, limit: limit, lineLimit: lineLimit)
    var partsDigits = 1
    while true {
      let ranges = try layout.pack(file.lines, partsDigits: partsDigits)
      let needed = CodecPartLayout.digits(ranges.count)
      if needed <= partsDigits { return ranges }
      partsDigits = needed
    }
  }

  private static func logicalTag(header: BaseHeader, lines: [Data], key: VaultKey) -> ContentTag {
    let headerLine = CanonicalJSON.encode(.object(logicalMembers(header, totalLines: lines.count)))
    return ContentTag.make(lines: [headerLine] + lines, key: key)
  }

  private static func logicalMembers(_ header: BaseHeader, totalLines: Int) -> [String: JSONValue] {
    [
      "format": .int(CodecFrame.format),
      "kind": .string(kind),
      "lines": .int(Int64(totalLines)),
      "replica": .string(header.replica.description),
      "schema": .int(Int64(header.schema)),
      "through": header.through.map(CodecFrame.pointValue) ?? .null,
      "upto": .int(header.upTo),
    ]
  }

  private static func partHeaderValue(_ header: BaseHeader, totalLines: Int, count: Int, part: Int, parts: Int) -> JSONValue {
    var members = logicalMembers(header, totalLines: totalLines)
    members["count"] = .int(Int64(count))
    members["part"] = .int(Int64(part))
    members["parts"] = .int(Int64(parts))
    return .object(members)
  }
}

/// A part header holds `parts`, which is known only after packing, so packing assumes a digit count for it and repeats until that holds.
private struct CodecPartLayout {
  let fixedHeaderBytes: Int
  let limit: Int
  let lineLimit: Int

  static func digits(_ value: Int) -> Int {
    String(value).count
  }

  func pack(_ lines: [Data], partsDigits: Int) throws(VaultCodecError) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start = 0
    var lineBytes = 0
    for (index, line) in lines.enumerated() {
      let added = line.count + 1
      let count = index - start + 1
      if count <= lineLimit, headerBytes(count: count, part: ranges.count + 1, partsDigits: partsDigits) + lineBytes + added <= limit {
        lineBytes += added
        continue
      }
      guard index > start else { throw .lineTooLarge(index: index) }
      ranges.append(start..<index)
      guard ranges.count < VaultPath.maximumParts else { throw .tooManyParts }
      guard headerBytes(count: 1, part: ranges.count + 1, partsDigits: partsDigits) + added <= limit else { throw .lineTooLarge(index: index) }
      start = index
      lineBytes = added
    }
    guard headerBytes(count: lines.count - start, part: ranges.count + 1, partsDigits: partsDigits) + lineBytes <= limit else { throw .payloadTooLarge }
    ranges.append(start..<lines.count)
    return ranges
  }

  private func headerBytes(count: Int, part: Int, partsDigits: Int) -> Int {
    fixedHeaderBytes + Self.digits(count) + Self.digits(part) + partsDigits
  }
}
