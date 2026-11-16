import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@Suite("ReplicaID")
struct ReplicaIDTests {
  private static let text = "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b"

  @Test("should round trip through its canonical text")
  func shouldRoundTripThroughCanonicalText() throws {
    let replica = try #require(ReplicaID(Self.text))
    #expect(replica.description == Self.text)
    #expect(ReplicaID(replica.description) == replica)
    #expect(ReplicaID(replica.uuid) == replica)
  }

  @Test(
    "should reject non canonical text",
    arguments: [
      "",
      "0193A1B2-7C3D-7E4F-8A5B-6C7D8E9F0A1B",
      "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0A1b",
      "0193a1b27c3d7e4f8a5b6c7d8e9f0a1b",
      "{0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b}",
      " 0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1b ",
      "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1",
      "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1bc",
      "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1g",
      "0193a1b2_7c3d-7e4f-8a5b-6c7d8e9f0a1b",
      "0193a1b2-7c3d-7e4f-8a5b-6c7d8e9f0a1\u{0662}",
    ])
  func shouldRejectNonCanonicalText(text: String) {
    #expect(ReplicaID(text) == nil)
  }

  @Test("should order by the lower case text")
  func shouldOrderByLowerCaseText() throws {
    try forAll { generator in
      let first = ReplicaID(UUID(uuid: Self.randomUUIDBytes(&generator)))
      let second = ReplicaID(UUID(uuid: Self.randomUUIDBytes(&generator)))
      #expect((first < second) == Array(first.description.utf8).lexicographicallyPrecedes(Array(second.description.utf8)))
      #expect((first < second) == (first.uuid.uuidString.lowercased() < second.uuid.uuidString.lowercased()))
    }
  }

  @Test("should encode as a single JSON string")
  func shouldEncodeAsSingleJSONString() throws {
    let replica = try #require(ReplicaID(Self.text))
    let data = try JSONEncoder().encode(replica)
    #expect(String(decoding: data, as: UTF8.self) == "\"\(Self.text)\"")
    #expect(try JSONDecoder().decode(ReplicaID.self, from: data) == replica)
  }

  @Test("should fail to decode a non canonical string")
  func shouldFailToDecodeNonCanonicalString() {
    let data = Data("\"0193A1B2-7C3D-7E4F-8A5B-6C7D8E9F0A1B\"".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReplicaID.self, from: data) }
  }

  static func randomUUIDBytes(_ generator: inout SeededGenerator) -> uuid_t {
    let bytes = generator.data(count: 16)
    return (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
  }
}
