import Foundation

import ShadowCore

enum CodecFrame {
  static let format: Int64 = 1
  static let maximumLineCount = 1_048_576
  static let newline: UInt8 = 0x0A
  static let storedCodec: UInt8 = 0
  static let deflateCodec: UInt8 = 1

  static func isValidLine(_ line: Data) -> Bool {
    !line.isEmpty && !line.contains(newline)
  }

  static func payload(header: JSONValue, lines: some Collection<Data>) -> Data {
    let headerLine = CanonicalJSON.encode(header)
    var payload = Data(capacity: lines.reduce(headerLine.count + 1) { $0 + $1.count + 1 })
    payload.append(headerLine)
    payload.append(newline)
    for line in lines {
      payload.append(line)
      payload.append(newline)
    }
    return payload
  }

  static func body(of payload: Data) -> Data {
    guard let deflated = CodecDeflate.deflate(payload, capacity: payload.count - 1) else { return Data([storedCodec]) + payload }
    return Data([deflateCodec]) + deflated
  }

  static func seal(_ payload: Data, at key: ObjectKey, vault: VaultID, with sealingKey: VaultKey) throws(VaultCodecError) -> Data {
    do {
      return try VaultFile.seal(body(of: payload), path: key.rawValue, vault: vault, key: sealingKey)
    } catch {
      throw .file(error)
    }
  }

  static func open(_ data: Data, at key: ObjectKey, vault: VaultID, keys: (KeyID) -> VaultKey?, limit: Int) throws(VaultCodecError) -> (payload: Data, key: VaultKey) {
    var openingKey: VaultKey?
    let body: Data
    do {
      body = try VaultFile.open(data, path: key.rawValue, vault: vault) { keyID in
        let found = keys(keyID)
        openingKey = found
        return found
      }
    } catch {
      throw .file(error)
    }
    guard let openingKey else { throw .file(.cryptoFailure) }
    return (try payload(ofBody: body, limit: limit), openingKey)
  }

  static func payload(ofBody body: Data, limit: Int) throws(VaultCodecError) -> Data {
    guard let codec = body.first else { throw .malformed("no codec byte") }
    let content = Data(body.dropFirst())
    switch codec {
    case storedCodec:
      guard content.count <= limit else { throw .payloadTooLarge }
      return content
    case deflateCodec:
      return try CodecDeflate.inflate(content, limit: limit)
    default:
      throw .unsupportedCodec(codec)
    }
  }

  static func headerLine(of payload: Data) throws(VaultCodecError) -> (line: Data, linesStart: Int) {
    let end = payload.withUnsafeBytes { $0.firstIndex(of: newline) }
    guard let end else { throw .malformed("no header line") }
    guard end > 0 else { throw .malformed("empty header line") }
    return (Data(payload.prefix(end)), end + 1)
  }

  static func lines(of payload: Data, from offset: Int, limit: Int) throws(VaultCodecError) -> [Data] {
    let result: Result<[Data], VaultCodecError> = payload.withUnsafeBytes { raw in
      var lines: [Data] = []
      var start = offset
      while start < raw.count {
        guard let end = raw[start...].firstIndex(of: newline) else { return .failure(.malformed("missing final newline")) }
        guard end > start else { return .failure(.malformed("empty line")) }
        guard lines.count < limit else { return .failure(.malformed("more lines than counted")) }
        lines.append(Data(UnsafeRawBufferPointer(rebasing: raw[start..<end])))
        start = end + 1
      }
      return .success(lines)
    }
    return try result.get()
  }

  static func pointValue(_ point: StreamPoint) -> JSONValue {
    .object(["last": .int(point.last), "tag": .string(point.tag.description)])
  }
}

struct CodecFields {
  private static let pointMembers: Set<String> = ["last", "tag"]

  private let members: [String: JSONValue]

  init(line: Data, kind: String, members expected: Set<String>) throws(VaultCodecError) {
    let value: JSONValue
    do {
      value = try CanonicalJSON.decode(line, mode: .lenient)
    } catch {
      throw .malformed("header is not JSON")
    }
    guard case .object(let members) = value else { throw .malformed("header is not an object") }
    guard case .int(let format)? = members["format"] else { throw .malformed("header has no format") }
    guard format == CodecFrame.format else { throw .unsupportedFormat(format) }
    guard members["kind"] == .string(kind) else { throw .malformed("header is not a \(kind) header") }
    guard Set(members.keys) == expected else { throw .malformed("header members differ") }
    guard CanonicalJSON.encode(value) == line else { throw .malformed("header is not canonical") }
    self.members = members
  }

  func int(_ name: String) throws(VaultCodecError) -> Int64 {
    guard case .int(let value)? = members[name] else { throw .malformed("\(name) is not an integer") }
    return value
  }

  func count(_ name: String) throws(VaultCodecError) -> Int {
    guard let value = Int(exactly: try int(name)), value >= 0 else { throw .malformed("\(name) is out of range") }
    return value
  }

  func replica(_ name: String) throws(VaultCodecError) -> ReplicaID {
    guard case .string(let text)? = members[name], let replica = ReplicaID(text) else { throw .malformed("\(name) is not a replica id") }
    return replica
  }

  func point(_ name: String) throws(VaultCodecError) -> StreamPoint? {
    guard let value = members[name] else { throw .malformed("\(name) is missing") }
    if value.isNull { return nil }
    return try Self.point(value, name: name)
  }

  func points(_ name: String) throws(VaultCodecError) -> [ReplicaID: StreamPoint] {
    guard case .object(let entries)? = members[name] else { throw .malformed("\(name) is not an object") }
    var points: [ReplicaID: StreamPoint] = [:]
    for (text, value) in entries {
      guard let replica = ReplicaID(text) else { throw .malformed("\(name) names an invalid replica id") }
      points[replica] = try Self.point(value, name: name)
    }
    return points
  }

  private static func point(_ value: JSONValue, name: String) throws(VaultCodecError) -> StreamPoint {
    guard case .object(let members) = value, Set(members.keys) == pointMembers else { throw .malformed("\(name) is not a stream point") }
    guard case .int(let last)? = members["last"], case .string(let text)? = members["tag"], let tag = ContentTag(text) else { throw .malformed("\(name) is not a stream point") }
    return StreamPoint(last: last, tag: tag)
  }
}
