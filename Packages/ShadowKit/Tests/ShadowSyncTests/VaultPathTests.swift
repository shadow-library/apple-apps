import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("VaultPath")
struct VaultPathTests {
  static let replica = "01936f3e-1111-7111-8111-111111111111"
  static let tag = "0123456789abcdef0123456789abcdef"
  static let keyID = "01936f3e-0000-7000-8000-000000000001"
  static let blob = String(repeating: "ab", count: 32)
  static let objectKeyCharacters = Array("abcdefABCDEF0123456789-_./")

  static let canonical: [String] = [
    "vault.json",
    "replicas/\(replica)/manifest",
    "replicas/\(replica)/seg/000000000001-000000000001-\(tag)",
    "replicas/\(replica)/seg/000000000005-999999999999-\(tag)",
    "replicas/\(replica)/base/000000000000-\(tag)/0001-of-0001",
    "replicas/\(replica)/base/000000000042-\(tag)/0002-of-9999",
    "keys/0123456789abcdef/\(keyID)",
    "blobs/\(blob)/0001-of-0003",
  ]

  static let nearMisses: [String] = [
    "vault.json.bak", "Vault.json", "vault.json/x", "replicas", "replicas/\(replica)",
    "replicas/\(replica)/manifest.bak", "replicas/\(replica)/manifest/x", "replicas/\(replica)/Manifest", "replicas/\(replica.uppercased())/manifest",
    "replicas/01936f3e11117111811111111111111/manifest", "replicas/\(replica)/other",
    "replicas/\(replica)/seg/00000000001-000000000001-\(tag)", "replicas/\(replica)/seg/0000000000001-000000000001-\(tag)",
    "replicas/\(replica)/seg/000000000000-000000000001-\(tag)", "replicas/\(replica)/seg/000000000002-000000000001-\(tag)",
    "replicas/\(replica)/seg/000000000001-000000000001-\(tag.uppercased())", "replicas/\(replica)/seg/000000000001-000000000001-\(tag)0",
    "replicas/\(replica)/seg/000000000001-000000000001-\(tag.dropLast())", "replicas/\(replica)/seg/000000000001_000000000001-\(tag)",
    "replicas/\(replica)/seg/000000000001-000000000001-\(tag)/x", "replicas/\(replica)/seg/00000000000a-000000000001-\(tag)",
    "replicas/\(replica)/seg/-00000000001-000000000001-\(tag)", "replicas/\(replica)/seg", "replicas/\(replica)/seg/000000000001-000000000001",
    "replicas/\(replica)/base/000000000000-\(tag)", "replicas/\(replica)/base/000000000000-\(tag)/0000-of-0001",
    "replicas/\(replica)/base/000000000000-\(tag)/0002-of-0001", "replicas/\(replica)/base/000000000000-\(tag)/001-of-0001",
    "replicas/\(replica)/base/000000000000-\(tag)/0001-of-00001", "replicas/\(replica)/base/000000000000-\(tag)/0001-OF-0001",
    "replicas/\(replica)/base/000000000000-\(tag)/0001-of-0001/x", "replicas/\(replica)/base/00000000000-\(tag)/0001-of-0001",
    "replicas/\(replica)/base/000000000000-\(tag.uppercased())/0001-of-0001", "replicas/\(replica)/base/000000000000-\(tag)x/0001-of-0001",
    "keys/0123456789abcde/\(keyID)", "keys/0123456789abcdef0/\(keyID)", "keys/0123456789ABCDEF/\(keyID)", "keys/0123456789abcdef/\(keyID.uppercased())",
    "keys/0123456789abcdef/\(keyID)/x", "keys/0123456789abcdef", "blobs/\(blob)", "blobs/\(blob.dropLast())/0001-of-0001", "blobs/\(blob)/0001-of-0000",
    "blobs/\(blob.uppercased())/0001-of-0001", "blobs/\(blob)/0001-of-0001/x", "blobs/\(blob)/0001-of-0001x", "other/file", "seg/000000000001",
  ]

  @Test("should classify canonical keys and rebuild them exactly", arguments: canonical)
  func shouldClassifyCanonicalKeys(text: String) throws {
    let key = try CodecFixtures.objectKey(text)
    let object = VaultPath.classify(key)
    #expect(object != .unknown)
    #expect(Self.build(object) == key)
  }

  @Test("should classify near misses as unknown", arguments: nearMisses)
  func shouldRejectNearMisses(text: String) throws {
    #expect(VaultPath.classify(try CodecFixtures.objectKey(text)) == .unknown)
  }

  @Test("should spell the fixed names and prefixes")
  func shouldSpellNames() throws {
    let replica = try CodecFixtures.replica(Self.replica)
    let tag = try CodecFixtures.tag(Self.tag)
    #expect(VaultPath.hint.rawValue == "vault.json")
    #expect(VaultPath.replicasPrefix == "replicas/")
    #expect(VaultPath.replicaPrefix(replica) == "replicas/\(Self.replica)/")
    #expect(VaultPath.segmentPrefix(replica) == "replicas/\(Self.replica)/seg/")
    #expect(VaultPath.basePrefix(replica) == "replicas/\(Self.replica)/base/")
    #expect(VaultPath.manifest(replica).rawValue == "replicas/\(Self.replica)/manifest")
    #expect(VaultPath.segment(replica, first: 12, last: 345, tag: tag).rawValue == "replicas/\(Self.replica)/seg/000000000012-000000000345-\(Self.tag)")
    #expect(VaultPath.basePart(replica, upTo: 7, tag: tag, part: 2, parts: 3).rawValue == "replicas/\(Self.replica)/base/000000000007-\(Self.tag)/0002-of-0003")
    #expect(VaultPath.sealedKey(recipient: "0123456789abcdef", key: try #require(KeyID(Self.keyID))).rawValue == "keys/0123456789abcdef/\(Self.keyID)")
    #expect(VaultPath.blobPart(name: Self.blob, part: 1, parts: 1).rawValue == "blobs/\(Self.blob)/0001-of-0001")
  }

  @Test("should classify every built object back to itself")
  func shouldRoundTripBuiltObjects() throws {
    try forAll(iterations: 500) { generator in
      let object = try Self.object(&generator)
      let key = try #require(Self.build(object))
      #expect(VaultPath.classify(key) == object)
    }
  }

  @Test("should rebuild the identical key for every mutated key that still classifies")
  func shouldRebuildMutatedKeys() throws {
    try forAll(iterations: 1000) { generator in
      var characters = Array(try #require(Self.build(try Self.object(&generator))).rawValue)
      for _ in 0..<generator.int(in: 1...3) {
        let index = generator.int(in: 0...(characters.count - 1))
        switch generator.int(in: 0...2) {
        case 0: characters[index] = generator.pick(from: Self.objectKeyCharacters)
        case 1: characters.insert(generator.pick(from: Self.objectKeyCharacters), at: index)
        default: if characters.count > 1 { characters.remove(at: index) }
        }
      }
      guard let key = ObjectKey(String(characters)) else { return }
      let object = VaultPath.classify(key)
      guard object != .unknown else { return }
      #expect(Self.build(object) == key)
    }
  }

  @Test("should never trap on random object keys")
  func shouldNotTrapOnRandomKeys() throws {
    try forAll(iterations: 2000) { generator in
      let length = generator.int(in: 1...120)
      let text = String((0..<length).map { _ in generator.pick(from: Self.objectKeyCharacters) })
      guard let key = ObjectKey(text) else { return }
      let object = VaultPath.classify(key)
      if object != .unknown { #expect(Self.build(object) == key) }
    }
  }

  @Test("should order segment keys by byte the same as by first sequence")
  func shouldOrderSegmentKeysNumerically() throws {
    try forAll(iterations: 50) { generator in
      let replica = try CodecFixtures.replica(&generator)
      var firsts: Set<Int64> = []
      while firsts.count < 20 { firsts.insert(CodecFixtures.sequence(&generator)) }
      let keys = try firsts.map { first in VaultPath.segment(replica, first: first, last: first, tag: try CodecFixtures.tag(&generator)) }
      let orderedFirsts = keys.sorted().compactMap { key -> Int64? in
        guard case .segment(_, let first, _, _) = VaultPath.classify(key) else { return nil }
        return first
      }
      #expect(orderedFirsts == firsts.sorted())
    }
  }

  static func object(_ generator: inout SeededGenerator) throws -> VaultObject {
    let parts = generator.chance(0.3) ? generator.pick(from: [1, 9999]) : generator.int(in: 1...9999)
    let part = generator.int(in: 1...parts)
    switch generator.int(in: 0...5) {
    case 0:
      return .hint
    case 1:
      return .manifest(try CodecFixtures.replica(&generator))
    case 2:
      let first = CodecFixtures.sequence(&generator)
      let last = generator.chance(0.3) ? first : Int64(generator.int(in: Int(first)...999_999_999_999))
      return .segment(try CodecFixtures.replica(&generator), first: first, last: last, tag: try CodecFixtures.tag(&generator))
    case 3:
      let upTo = generator.chance(0.2) ? 0 : CodecFixtures.sequence(&generator)
      return .basePart(try CodecFixtures.replica(&generator), upTo: upTo, tag: try CodecFixtures.tag(&generator), part: part, parts: parts)
    case 4:
      return .sealedKey(recipient: CodecFixtures.hex(&generator, count: 16), key: try CodecFixtures.keyID(&generator))
    default:
      return .blobPart(name: CodecFixtures.hex(&generator, count: 64), part: part, parts: parts)
    }
  }

  static func build(_ object: VaultObject) -> ObjectKey? {
    switch object {
    case .hint: VaultPath.hint
    case .manifest(let replica): VaultPath.manifest(replica)
    case .segment(let replica, let first, let last, let tag): VaultPath.segment(replica, first: first, last: last, tag: tag)
    case .basePart(let replica, let upTo, let tag, let part, let parts): VaultPath.basePart(replica, upTo: upTo, tag: tag, part: part, parts: parts)
    case .sealedKey(let recipient, let key): VaultPath.sealedKey(recipient: recipient, key: key)
    case .blobPart(let name, let part, let parts): VaultPath.blobPart(name: name, part: part, parts: parts)
    case .unknown: nil
    }
  }
}
