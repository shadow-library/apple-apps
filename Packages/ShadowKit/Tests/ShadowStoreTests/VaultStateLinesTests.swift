import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

private func decodeFailure(_ lines: [Data]) -> VaultStateError? {
  do {
    _ = try VaultState(decodingLines: lines)
    return nil
  } catch {
    return error
  }
}

private func lines(_ texts: [String]) -> [Data] {
  texts.map { Data($0.utf8) }
}

private let header = "{\"format\":\"shadow.vault-state\",\"type\":\"header\",\"version\":1}"
private let clockText = "2023-11-14T22:13:20.001Z-0000-00000000-0000-0000-0000-00000000000a"

@Suite("VaultState lines")
struct VaultStateLinesTests {
  @Test("should encode an empty state as the header alone")
  func shouldEncodeEmptyState() {
    #expect(VaultState().encodedLines() == lines([header]))
    #expect(VaultState().digest == "302e0a6c41706d30d22733261f8a54996905fcc534acf8f6c189552f4070fbb3")
  }

  @Test("should write one self-describing line per entity, then one per foreign record")
  func shouldWriteDocumentedLayout() {
    let foreign = Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1))
    var state = Fixture.state([
      foreign, Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["status": "draft"]),
      Fixture.change(.purge, Fixture.message, Fixture.key("m1"), clock: Fixture.clock(1)),
    ])
    state.keepOpaque(Data([0xFF, 0x00]))
    let expected = [
      header,
      "{\"clock\":\"\(clockText)\",\"entity\":\"message\",\"key\":\"m1\",\"type\":\"purged\"}",
      "{\"entity\":\"note\",\"fields\":[{\"clock\":\"\(clockText)\",\"name\":\"status\",\"rule\":{\"kind\":\"monotone\",\"order\":[\"draft\",\"review\",\"final\"]},"
        + "\"value\":\"draft\"}],\"key\":\"k1\",\"type\":\"record\"}",
      "{\"record\":\(String(decoding: foreign.canonicalBytes(), as: UTF8.self)),\"type\":\"foreign\"}",
      "{\"line\":\"/wA=\",\"type\":\"opaque\"}",
    ]
    #expect(state.encodedLines() == lines(expected))
  }

  @Test("should round-trip random states exactly")
  func shouldRoundTripRandomStates() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      var state = Fixture.state(factory.changes(&generator)).retained(registry: generator.chance(0.5) ? Fixture.v1 : Fixture.v2)
      for _ in 0..<generator.int(in: 0...3) { state.keepOpaque(generator.opaqueLine()) }
      let decoded = try VaultState(decodingLines: state.encodedLines())
      try #require(decoded == state)
      try #require(decoded.digest == state.digest)
      try #require(decoded.encodedLines() == state.encodedLines())
    }
  }

  @Test("should reject a missing or foreign header")
  func shouldRejectMissingHeader() {
    #expect(decodeFailure([]) == .missingHeader)
    #expect(decodeFailure(lines(["{\"type\":\"record\"}"])) == .missingHeader)
    #expect(decodeFailure(lines(["{\"format\":\"other\",\"type\":\"header\",\"version\":1}"])) == .malformedLine(line: 0))
    #expect(decodeFailure(lines(["{\"format\":\"shadow.vault-state\",\"type\":\"header\",\"version\":2}"])) == .unsupportedVersion(2))
  }

  @Test(
    "should reject malformed lines",
    arguments: [
      "{\"entity\":\"note\",\"key\":\"k1\",\"type\":\"unknown\"}",
      "{\"entity\":\"note\",\"key\":\"k1\",\"type\":\"purged\"}",
      "{\"clock\":\"x\",\"entity\":\"note\",\"key\":\"k1\",\"type\":\"purged\"}",
      "{\"clock\":\"\(clockText)\",\"entity\":\"Note\",\"key\":\"k1\",\"type\":\"purged\"}",
      "{\"clock\":\"\(clockText)\",\"entity\":\"note\",\"extra\":1,\"key\":\"k1\",\"type\":\"purged\"}",
      "{\"entity\":\"note\",\"fields\":{},\"key\":\"k1\",\"type\":\"record\"}",
      "{\"entity\":\"note\",\"fields\":[{\"clock\":\"\(clockText)\",\"name\":\"s\",\"rule\":{\"kind\":\"monotone\",\"order\":[\"a\"]},\"value\":\"b\"}],\"key\":\"k1\",\"type\":\"record\"}",
      "{\"entity\":\"note\",\"fields\":[{\"clock\":\"\(clockText)\",\"name\":\"s\",\"rule\":{\"kind\":\"lww\"},\"value\":\"b\"}],\"key\":\"k1\",\"type\":\"record\"}",
      "{\"entity\":\"note\",\"fields\":[{\"clock\":\"\(clockText)\",\"name\":\"b\",\"rule\":{\"kind\":\"register\"},\"value\":1},"
        + "{\"clock\":\"\(clockText)\",\"name\":\"a\",\"rule\":{\"kind\":\"register\"},\"value\":1}],\"key\":\"k1\",\"type\":\"record\"}",
      "{\"entity\":\"draft\",\"fields\":[],\"head\":{\"clock\":\"\(clockText)\",\"value\":\"v:x\"},\"key\":\"d1\",\"marks\":[],\"revisions\":[],\"type\":\"revisioned\"}",
      "{\"entity\":\"draft\",\"fields\":[],\"head\":null,\"key\":\"d1\",\"marks\":[{\"clock\":\"\(clockText)\",\"name\":\"approved\",\"value\":\"v:x\"}],\"revisions\":[],\"type\":\"revisioned\"}",
      "{\"entity\":\"draft\",\"fields\":[],\"head\":null,\"key\":\"d1\",\"marks\":[],\"revisions\":[{\"body\":1,\"created\":\"\(clockText)\",\"id\":\"v:x\",\"parent\":null}],\"type\":\"revisioned\"}",
      "{\"entity\":\"draft\",\"fields\":[],\"head\":null,\"key\":\"d1\",\"marks\":[],\"revisions\":[],\"type\":\"revisioned\"}",
      "{\"entity\":\"draft\",\"fields\":[],\"key\":\"d1\",\"revisions\":[],\"type\":\"revisioned\"}",
      "{\"entity\":\"note\",\"fields\":[],\"key\":\"k1\",\"type\":\"record\"}",
      "{\"line\":\"!!!!\",\"type\":\"opaque\"}",
      "{\"line\":1,\"type\":\"opaque\"}",
      "{\"clock\":\"\(clockText)\",\"entity\":\"message\",\"item\":[],\"key\":\"m1\",\"type\":\"appended\"}",
      "{\"record\":{\"kind\":\"set\"},\"type\":\"foreign\"}",
      "[]",
    ])
  func shouldRejectMalformedLines(_ line: String) {
    #expect(decodeFailure(lines([header, line])) == .malformedLine(line: 1))
  }

  @Test("should reject non-canonical JSON")
  func shouldRejectNonCanonicalJSON() {
    #expect(decodeFailure(lines([header, "{ \"type\": \"foreign\" }"])) == .invalidJSON(line: 1))
    #expect(decodeFailure(lines(["{\"version\":1,\"type\":\"header\",\"format\":\"shadow.vault-state\"}"])) == .invalidJSON(line: 0))
  }

  @Test("should reject duplicated or out-of-order lines")
  func shouldRejectOutOfOrderLines() throws {
    var state = Fixture.state([
      Fixture.change(.purge, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1)), Fixture.change(.purge, Fixture.note, Fixture.key("k2"), clock: Fixture.clock(1)),
      Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1)), Fixture.change(.set, Fixture.tag, Fixture.key("t2"), clock: Fixture.clock(1)),
    ])
    state.keepOpaque(Data([1]))
    state.keepOpaque(Data([2]))
    let encoded = state.encodedLines()
    try #require(encoded.count == 7)
    #expect(decodeFailure([encoded[0], encoded[6], encoded[5]]) == .outOfOrder(line: 2))
    #expect(decodeFailure([encoded[0], encoded[5], encoded[3]]) == .outOfOrder(line: 2))
    #expect(decodeFailure([encoded[0], encoded[5], encoded[1]]) == .outOfOrder(line: 2))
    #expect(decodeFailure([encoded[0], encoded[2], encoded[1]]) == .outOfOrder(line: 2))
    #expect(decodeFailure([encoded[0], encoded[1], encoded[1]]) == .outOfOrder(line: 2))
    #expect(decodeFailure([encoded[0], encoded[4], encoded[3]]) == .outOfOrder(line: 2))
    #expect(decodeFailure([encoded[0], encoded[3], encoded[1]]) == .outOfOrder(line: 2))
    #expect(decodeFailure([encoded[0], encoded[1], encoded[0]]) == .malformedLine(line: 2))
  }

  @Test("should reject a foreign line under a purged entity unless it is a purge")
  func shouldRejectForeignOfPurgedEntity() throws {
    let purged = Fixture.state([Fixture.change(.purge, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1))]).encodedLines()
    let foreignSet = Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(2), fields: ["pinned": 1])
    let foreignPurge = Fixture.change(.purge, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(2), fields: ["reason": 1])
    let line = { (record: ChangeRecord) in CanonicalJSON.encode(["record": record.json, "type": "foreign"]) }
    #expect(decodeFailure(purged + [line(foreignSet)]) == .malformedLine(line: 2))
    #expect(try VaultState(decodingLines: purged + [line(foreignPurge)]).foreign == [foreignPurge])
  }

  @Test("should throw on random garbage")
  func shouldThrowOnGarbage() throws {
    try forAll(iterations: 300) { generator in
      var garbage = (0..<generator.int(in: 1...4)).map { _ in generator.data(count: generator.int(in: 0...40)) }
      if generator.chance(0.5) { garbage.insert(Data(header.utf8), at: 0) }
      try #require(decodeFailure(garbage) != nil)
    }
  }

  @Test("should throw when a valid encoding is truncated or corrupted")
  func shouldThrowOnCorruptedEncoding() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      var encoded = Fixture.state(factory.changes(&generator)).encodedLines()
      guard encoded.count > 1 else { return }
      let index = generator.int(in: 1...(encoded.count - 1))
      let line = encoded[index]
      encoded[index] = line.prefix(generator.int(in: 0...(line.count - 1)))
      try #require(decodeFailure(encoded) != nil)
    }
  }

  @Test("should expose a stable code for every error")
  func shouldExposeStableCodes() {
    #expect(VaultStateError.missingHeader.code == "vault_state.missing_header")
    #expect(VaultStateError.unsupportedVersion(2).code == "vault_state.unsupported_version")
    #expect(VaultStateError.invalidJSON(line: 1).code == "vault_state.invalid_json")
    #expect(VaultStateError.malformedLine(line: 1).code == "vault_state.malformed_line")
    #expect(VaultStateError.outOfOrder(line: 1).code == "vault_state.out_of_order")
  }
}
