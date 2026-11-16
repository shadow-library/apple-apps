import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

enum CodecFixtures {
  static let hexDigits = Array("0123456789abcdef")

  static func vault(_ rawValue: String = "vault-one") throws -> VaultID {
    try #require(VaultID(rawValue))
  }

  static func key(id: String = "01936f3e-0000-7000-8000-000000000001", byte: UInt8 = 0x42) throws -> VaultKey {
    let keyID = try #require(KeyID(id))
    return try #require(VaultKey(id: keyID, rawBytes: Data(repeating: byte, count: 32)))
  }

  static func ring(_ keys: VaultKey...) -> (KeyID) -> VaultKey? {
    { id in keys.first { $0.id == id } }
  }

  static func replica(_ text: String) throws -> ReplicaID {
    try #require(ReplicaID(text))
  }

  static func tag(_ text: String) throws -> ContentTag {
    try #require(ContentTag(text))
  }

  static func objectKey(_ text: String) throws -> ObjectKey {
    try #require(ObjectKey(text))
  }

  static func hex(_ generator: inout SeededGenerator, count: Int) -> String {
    String((0..<count).map { _ in generator.pick(from: hexDigits) })
  }

  static func tag(_ generator: inout SeededGenerator) throws -> ContentTag {
    try #require(ContentTag(hex(&generator, count: 32)))
  }

  static func replica(_ generator: inout SeededGenerator) throws -> ReplicaID {
    let digits = hex(&generator, count: 32)
    let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
      String(digits[digits.index(digits.startIndex, offsetBy: range.lowerBound)..<digits.index(digits.startIndex, offsetBy: range.upperBound)])
    }
    return try #require(ReplicaID(groups.joined(separator: "-")))
  }

  static func keyID(_ generator: inout SeededGenerator) throws -> KeyID {
    try #require(KeyID(try replica(&generator).description))
  }

  static func sequence(_ generator: inout SeededGenerator) -> Int64 {
    generator.chance(0.2) ? Int64(generator.pick(from: [1, 2, 9, 10, 999_999_999_998, 999_999_999_999])) : Int64(generator.int(in: 1...999_999_999_999))
  }

  static func line(_ generator: inout SeededGenerator, maxLength: Int = 40) -> Data {
    let length = generator.int(in: 1...max(1, maxLength))
    return Data((0..<length).map { _ in UInt8(generator.pick(from: Array(0...0x09) + Array(0x0B...0xFF))) })
  }

  static func lines(_ generator: inout SeededGenerator, count: Int, maxLength: Int = 40) -> [Data] {
    (0..<count).map { _ in line(&generator, maxLength: maxLength) }
  }

  static func segmentHeader(_ generator: inout SeededGenerator, maxLines: Int = 6) throws -> SegmentHeader {
    let replica = try replica(&generator)
    let first: Int64 = generator.chance(0.3) ? 1 : Int64(generator.int(in: 2...1_000_000))
    let last = first + Int64(generator.int(in: 0...(maxLines - 1)))
    let previous = first == 1 ? nil : StreamPoint(last: first - 1, tag: try tag(&generator))
    var dependencies: [ReplicaID: StreamPoint] = [:]
    for _ in 0..<generator.int(in: 0...3) {
      dependencies[try self.replica(&generator)] = StreamPoint(last: Int64(generator.int(in: 1...100_000)), tag: try tag(&generator))
    }
    let schema = generator.int(in: 0...50)
    return try #require(SegmentHeader(replica: replica, first: first, last: last, previous: previous, dependencies: dependencies, schema: schema))
  }

  static func segment(_ generator: inout SeededGenerator) throws -> SegmentFile {
    let header = try segmentHeader(&generator)
    return try #require(SegmentFile(header: header, lines: lines(&generator, count: Int(header.last - header.first + 1))))
  }

  static func sealBody(_ body: Data, at key: ObjectKey, vault: VaultID, with sealingKey: VaultKey) throws -> Data {
    try VaultFile.seal(body, path: key.rawValue, vault: vault, key: sealingKey)
  }

  static func sealPayload(_ payload: Data, at key: ObjectKey, vault: VaultID, with sealingKey: VaultKey, codec: UInt8 = 0) throws -> Data {
    let body = codec == CodecFrame.deflateCodec ? try #require(CodecDeflate.deflate(payload, capacity: payload.count + 1024)) : payload
    return try sealBody(Data([codec]) + body, at: key, vault: vault, with: sealingKey)
  }

  static func codecByte(of sealed: Data, at key: ObjectKey, vault: VaultID, keys: (KeyID) -> VaultKey?) throws -> UInt8? {
    try VaultFile.open(sealed, path: key.rawValue, vault: vault, keys: keys).first
  }

  static func isMalformed(_ error: VaultCodecError) -> Bool {
    guard case .malformed = error else { return false }
    return true
  }

  static func codecError(_ body: () throws -> Void) -> VaultCodecError? {
    do {
      try body()
      return nil
    } catch let error as VaultCodecError {
      return error
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }
}
