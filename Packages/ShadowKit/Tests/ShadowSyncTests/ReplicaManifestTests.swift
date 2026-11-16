import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("ReplicaManifest")
struct ReplicaManifestTests {
  private static let replicaText = "01936f3e-1111-7111-8111-111111111111"
  private static let otherText = "01936f3e-2222-7222-8222-222222222222"
  private static let headTag = "0123456789abcdef0123456789abcdef"
  private static let baseTag = "fedcba9876543210fedcba9876543210"
  private static let appliedTag = "00112233445566778899aabbccddeeff"
  private static let family = "👩‍👩‍👧‍👦"
  private static let goldenPayload =
    #"{"app":"1.2.0 (45)","applied":{"\#(otherText)":{"last":17,"tag":"\#(appliedTag)"}},"base":{"parts":2,"tag":"\#(baseTag)","upto":40},"#
    + #""device":"Leander's iPhone","format":1,"head":{"last":42,"tag":"\#(headTag)"},"platform":"iOS","replica":"\#(replicaText)","schema":3,"updated":1700000000000}"#

  private static func golden() throws -> ReplicaManifest {
    ReplicaManifest(
      replica: try CodecFixtures.replica(replicaText),
      deviceName: "Leander's iPhone",
      platform: "iOS",
      appVersion: "1.2.0 (45)",
      schema: 3,
      head: StreamPoint(last: 42, tag: try CodecFixtures.tag(headTag)),
      base: BaseReference(upTo: 40, tag: try CodecFixtures.tag(baseTag), parts: 2),
      applied: [try CodecFixtures.replica(otherText): StreamPoint(last: 17, tag: try CodecFixtures.tag(appliedTag))],
      updatedMillis: 1_700_000_000_000
    )
  }

  private static func validMembers() -> [String: JSONValue] {
    [
      "app": "1.0",
      "applied": [otherText: ["last": 3, "tag": .string(appliedTag)]],
      "base": ["parts": 1, "tag": .string(baseTag), "upto": 7],
      "device": "Phone",
      "format": 1,
      "head": ["last": 9, "tag": .string(headTag)],
      "platform": "iOS",
      "replica": .string(replicaText),
      "schema": 2,
      "updated": 5,
    ]
  }

  private static func sealed(_ members: [String: JSONValue], at replica: String = replicaText) throws -> (key: ObjectKey, data: Data) {
    try sealed(CanonicalJSON.encode(.object(members)), at: replica)
  }

  private static func sealed(_ payload: Data, at replica: String = replicaText) throws -> (key: ObjectKey, data: Data) {
    let key = VaultPath.manifest(try CodecFixtures.replica(replica))
    return (key, try VaultFile.seal(payload, path: key.rawValue, vault: try CodecFixtures.vault(), key: try CodecFixtures.key()))
  }

  private static func open(_ file: (key: ObjectKey, data: Data), at key: ObjectKey? = nil) throws -> ReplicaManifest {
    try ReplicaManifestCodec.open(file.data, at: key ?? file.key, vault: try CodecFixtures.vault(), keys: CodecFixtures.ring(try CodecFixtures.key()))
  }

  private static func openError(_ file: (key: ObjectKey, data: Data), at key: ObjectKey? = nil) -> ReplicaFileError? {
    do {
      _ = try open(file, at: key)
      return nil
    } catch let error as ReplicaFileError {
      return error
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }

  private static func isMalformed(_ error: ReplicaFileError?) -> Bool {
    guard case .malformed? = error else { return false }
    return true
  }

  private static func randomManifest(_ generator: inout SeededGenerator) throws -> ReplicaManifest {
    let replica = try CodecFixtures.replica(&generator)
    var applied: [ReplicaID: StreamPoint] = [:]
    for _ in 0..<generator.int(in: 0...4) {
      let peer = try CodecFixtures.replica(&generator)
      if peer != replica { applied[peer] = StreamPoint(last: Int64(generator.int(in: 1...1_000_000)), tag: try CodecFixtures.tag(&generator)) }
    }
    return ReplicaManifest(
      replica: replica,
      deviceName: generator.chance(0.2) ? String(repeating: family, count: generator.int(in: 1...40)) : generator.unicodeString(maxLength: 120),
      platform: generator.pick(from: ["iOS", "iPadOS", "macOS", "visionOS"]),
      appVersion: generator.asciiString(maxLength: 20),
      schema: generator.int(in: 0...100),
      head: generator.chance(0.5) ? nil : StreamPoint(last: CodecFixtures.sequence(&generator), tag: try CodecFixtures.tag(&generator)),
      base: generator.chance(0.5)
        ? nil : BaseReference(upTo: Int64(generator.int(in: 0...999_999_999_999)), tag: try CodecFixtures.tag(&generator), parts: generator.int(in: 1...9999)),
      applied: applied,
      updatedMillis: Int64(generator.int(in: 0...Int.max))
    )
  }

  @Test("should validate base references")
  func shouldValidateBaseReference() throws {
    let tag = try CodecFixtures.tag(Self.baseTag)
    #expect(BaseReference(upTo: 0, tag: tag, parts: 1) != nil)
    #expect(BaseReference(upTo: 999_999_999_999, tag: tag, parts: 9999) != nil)
    #expect(BaseReference(upTo: -1, tag: tag, parts: 1) == nil)
    #expect(BaseReference(upTo: 1_000_000_000_000, tag: tag, parts: 1) == nil)
    #expect(BaseReference(upTo: 1, tag: tag, parts: 0) == nil)
    #expect(BaseReference(upTo: 1, tag: tag, parts: 10_000) == nil)
  }

  @Test("should pin the payload of the golden manifest")
  func shouldMatchGolden() throws {
    let manifest = try Self.golden()
    #expect(String(decoding: ReplicaManifestCodec.payload(of: manifest), as: UTF8.self) == Self.goldenPayload)
    let sealed = try ReplicaManifestCodec.seal(manifest, vault: try CodecFixtures.vault(), with: try CodecFixtures.key())
    #expect(sealed.key.rawValue == "replicas/\(Self.replicaText)/manifest")
    #expect(try Self.open(sealed) == manifest)
    #expect(
      try VaultFile.open(sealed.data, path: sealed.key.rawValue, vault: try CodecFixtures.vault(), keys: CodecFixtures.ring(try CodecFixtures.key()))
        == Data(Self.goldenPayload.utf8))
  }

  @Test("should encode empty head, base and applied as null and an empty object")
  func shouldEncodeEmpty() throws {
    var manifest = try Self.golden()
    manifest.head = nil
    manifest.base = nil
    manifest.applied = [:]
    let text = String(decoding: ReplicaManifestCodec.payload(of: manifest), as: UTF8.self)
    #expect(text.contains(#""applied":{},"base":null,"#) && text.contains(#""head":null,"#))
    #expect(try Self.open(try ReplicaManifestCodec.seal(manifest, vault: try CodecFixtures.vault(), with: try CodecFixtures.key())) == manifest)
  }

  @Test("should round trip random manifests")
  func shouldRoundTrip() throws {
    let vault = try CodecFixtures.vault()
    let key = try CodecFixtures.key()
    try forAll(iterations: 150) { generator in
      let manifest = try Self.randomManifest(&generator)
      let opened = try Self.open(try ReplicaManifestCodec.seal(manifest, vault: vault, with: key))
      #expect(opened.replica == manifest.replica && opened.schema == manifest.schema && opened.head == manifest.head)
      #expect(opened.base == manifest.base && opened.applied == manifest.applied && opened.updatedMillis == manifest.updatedMillis)
      for (original, stored) in [(manifest.deviceName, opened.deviceName), (manifest.platform, opened.platform), (manifest.appVersion, opened.appVersion)] {
        #expect(stored.utf8.count <= 256)
        #expect(original.unicodeScalars.starts(with: stored.unicodeScalars))
        if original.utf8.count <= 256 { #expect(stored.unicodeScalars.elementsEqual(original.unicodeScalars)) }
      }
    }
  }

  @Test("should keep emoji and clamp long names at a character boundary")
  func shouldClampNames() throws {
    var manifest = try Self.golden()
    manifest.deviceName = "Phone 📱 \(Self.family)"
    #expect(try Self.open(try ReplicaManifestCodec.seal(manifest, vault: try CodecFixtures.vault(), with: try CodecFixtures.key())).deviceName == manifest.deviceName)
    manifest.deviceName = String(repeating: Self.family, count: 30)
    manifest.platform = String(repeating: "é", count: 200)
    manifest.appVersion = String(repeating: "a", count: 300)
    let opened = try Self.open(try ReplicaManifestCodec.seal(manifest, vault: try CodecFixtures.vault(), with: try CodecFixtures.key()))
    #expect(opened.deviceName == String(repeating: Self.family, count: 10))
    #expect(opened.deviceName.utf8.count == 250)
    #expect(opened.platform == String(repeating: "é", count: 128))
    #expect(opened.appVersion == String(repeating: "a", count: 256))
    #expect(String(validating: Array(opened.deviceName.utf8), as: UTF8.self) != nil)
  }

  private static func sealError(_ manifest: ReplicaManifest) throws -> ReplicaFileError? {
    let vault = try CodecFixtures.vault()
    let key = try CodecFixtures.key()
    do {
      _ = try ReplicaManifestCodec.seal(manifest, vault: vault, with: key)
      return nil
    } catch {
      return error
    }
  }

  private static func randomlyBrokenManifest(_ generator: inout SeededGenerator) throws -> ReplicaManifest {
    var manifest = try randomManifest(&generator)
    let tag = try CodecFixtures.tag(&generator)
    let past = VaultPath.maximumSequence + 1
    switch generator.int(in: 0...12) {
    case 0: manifest.schema = generator.pick(from: [-1, Int(Int32.max) + 1, Int.max, Int.min, Int(Int32.max)])
    case 1: manifest.updatedMillis = generator.pick(from: [-1, Int64.min, 0, Int64.max])
    case 2: manifest.head = StreamPoint(last: generator.pick(from: [0, -1, past, Int64.max, 1, VaultPath.maximumSequence]), tag: tag)
    case 3: manifest.applied[try CodecFixtures.replica(&generator)] = StreamPoint(last: generator.pick(from: [0, past, 5]), tag: tag)
    case 4: manifest.applied[manifest.replica] = StreamPoint(last: 1, tag: tag)
    case 5: manifest.deviceName = String(repeating: "x", count: generator.int(in: 250...262))
    default: break
    }
    return manifest
  }

  @Test("should refuse to seal a manifest that open would reject")
  func shouldRefuseInvalidSeal() throws {
    let tag = try CodecFixtures.tag(Self.headTag)
    let peer = try CodecFixtures.replica(Self.otherText)
    let past = VaultPath.maximumSequence + 1
    let edits: [(String, (inout ReplicaManifest) -> Void)] = [
      ("head zero", { $0.head = StreamPoint(last: 0, tag: tag) }),
      ("head negative", { $0.head = StreamPoint(last: -4, tag: tag) }),
      ("head past the path limit", { $0.head = StreamPoint(last: past, tag: tag) }),
      ("applied zero", { $0.applied[peer] = StreamPoint(last: 0, tag: tag) }),
      ("applied past the path limit", { $0.applied[peer] = StreamPoint(last: past, tag: tag) }),
      ("applied self", { $0.applied[$0.replica] = StreamPoint(last: 1, tag: tag) }),
      ("schema negative", { $0.schema = -1 }),
      ("schema above Int32.max", { $0.schema = Int(Int32.max) + 1 }),
      ("updated negative", { $0.updatedMillis = -1 }),
    ]
    for (name, edit) in edits {
      var manifest = try Self.golden()
      edit(&manifest)
      #expect(Self.isMalformed(try Self.sealError(manifest)), "\(name)")
    }
  }

  @Test("should accept manifests exactly at every bound")
  func shouldAcceptBounds() throws {
    var manifest = try Self.golden()
    manifest.schema = Int(Int32.max)
    manifest.updatedMillis = Int64.max
    manifest.head = StreamPoint(last: VaultPath.maximumSequence, tag: try CodecFixtures.tag(Self.headTag))
    manifest.base = BaseReference(upTo: VaultPath.maximumSequence, tag: try CodecFixtures.tag(Self.baseTag), parts: 9999)
    #expect(try Self.open(try ReplicaManifestCodec.seal(manifest, vault: try CodecFixtures.vault(), with: try CodecFixtures.key())) == manifest)
  }

  @Test("should open every manifest that seal accepts and refuse the rest as malformed")
  func shouldValidateBothDirectionsAlike() throws {
    var accepted = 0
    var refused = 0
    try forAll(iterations: 400) { generator in
      let manifest = try Self.randomlyBrokenManifest(&generator)
      if let error = try Self.sealError(manifest) {
        refused += 1
        #expect(Self.isMalformed(error), "\(error)")
        return
      }
      accepted += 1
      let sealed = try ReplicaManifestCodec.seal(manifest, vault: try CodecFixtures.vault(), with: try CodecFixtures.key())
      #expect(try Self.open(sealed) == ReplicaManifestCodec.clamped(manifest))
    }
    #expect(accepted > 50 && refused > 50)
  }

  @Test("should ignore unknown members")
  func shouldIgnoreUnknownMembers() throws {
    var members = Self.validMembers()
    members["future"] = ["nested": [1, 2, 3]]
    let opened = try Self.open(try Self.sealed(members))
    #expect(opened.deviceName == "Phone" && opened.schema == 2 && opened.base?.upTo == 7)
  }

  @Test("should accept non canonical payload text")
  func shouldAcceptNonCanonical() throws {
    let pretty =
      "{\n \"format\" : 1, \"replica\" : \"\(Self.replicaText)\", \"app\":\"\", \"device\":\"\", \"platform\":\"\", \"schema\":0, \"updated\":0, \"head\":null, \"base\":null, \"applied\":{} }"
    #expect(try Self.open(try Self.sealed(Data(pretty.utf8))).head == nil)
  }

  @Test("should report an unsupported format before checking members")
  func shouldReportUnsupportedFormat() throws {
    var members = Self.validMembers()
    members["format"] = 2
    members["extra"] = "value"
    #expect(Self.openError(try Self.sealed(members)) == .unsupportedFormat(2))
    #expect(Self.openError(try Self.sealed(["format": 3])) == .unsupportedFormat(3))
  }

  @Test("should reject malformed payloads")
  func shouldRejectMalformed() throws {
    let long = JSONValue.string(String(repeating: "a", count: 257))
    let badPoint: (JSONValue) -> JSONValue = { last in ["last": last, "tag": .string(Self.headTag)] }
    let edits: [(String, (inout [String: JSONValue]) -> Void)] = [
      ("missing app", { $0["app"] = nil }),
      ("missing applied", { $0["applied"] = nil }),
      ("missing base", { $0["base"] = nil }),
      ("missing device", { $0["device"] = nil }),
      ("missing format", { $0["format"] = nil }),
      ("missing head", { $0["head"] = nil }),
      ("missing platform", { $0["platform"] = nil }),
      ("missing replica", { $0["replica"] = nil }),
      ("missing schema", { $0["schema"] = nil }),
      ("missing updated", { $0["updated"] = nil }),
      ("format zero", { $0["format"] = 0 }),
      ("format string", { $0["format"] = "1" }),
      ("device number", { $0["device"] = 5 }),
      ("schema string", { $0["schema"] = "3" }),
      ("schema negative", { $0["schema"] = -1 }),
      ("updated negative", { $0["updated"] = -1 }),
      ("updated null", { $0["updated"] = .null }),
      ("replica invalid", { $0["replica"] = "nope" }),
      ("replica uppercase", { $0["replica"] = .string(Self.replicaText.uppercased()) }),
      ("head array", { $0["head"] = [] }),
      ("head last zero", { $0["head"] = badPoint(0) }),
      ("head last past the path limit", { $0["head"] = badPoint(1_000_000_000_000) }),
      ("applied last past the path limit", { $0["applied"] = [Self.otherText: badPoint(1_000_000_000_000)] }),
      ("schema above Int32.max", { $0["schema"] = 2_147_483_648 }),
      ("head last string", { $0["head"] = badPoint("1") }),
      ("head bad tag", { $0["head"] = ["last": 1, "tag": "xyz"] }),
      ("head missing tag", { $0["head"] = ["last": 1] }),
      ("applied array", { $0["applied"] = [] }),
      ("applied bad key", { $0["applied"] = ["nope": badPoint(1)] }),
      ("applied last zero", { $0["applied"] = [Self.otherText: badPoint(0)] }),
      ("applied null point", { $0["applied"] = [Self.otherText: .null] }),
      ("applied self", { $0["applied"] = [Self.replicaText: badPoint(1)] }),
      ("base parts zero", { $0["base"] = ["parts": 0, "tag": .string(Self.baseTag), "upto": 1] }),
      ("base parts too many", { $0["base"] = ["parts": 10_000, "tag": .string(Self.baseTag), "upto": 1] }),
      ("base upto negative", { $0["base"] = ["parts": 1, "tag": .string(Self.baseTag), "upto": -1] }),
      ("base upto too large", { $0["base"] = ["parts": 1, "tag": .string(Self.baseTag), "upto": 1_000_000_000_000] }),
      ("base bad tag", { $0["base"] = ["parts": 1, "tag": "x", "upto": 1] }),
      ("base missing upto", { $0["base"] = ["parts": 1, "tag": .string(Self.baseTag)] }),
      ("base string", { $0["base"] = "none" }),
      ("device too long", { $0["device"] = long }),
      ("platform too long", { $0["platform"] = long }),
      ("app too long", { $0["app"] = long }),
    ]
    for (name, edit) in edits {
      var members = Self.validMembers()
      edit(&members)
      let error = Self.openError(try Self.sealed(members))
      #expect(Self.isMalformed(error), "\(name) gave \(String(describing: error))")
    }
    for text in ["[]", "null", "\"x\"", "not json", "", "{\"format\":1.0}"] {
      #expect(Self.isMalformed(Self.openError(try Self.sealed(Data(text.utf8)))), "\(text)")
    }
  }

  @Test("should accept a string of exactly the limit")
  func shouldAcceptLimitString() throws {
    var members = Self.validMembers()
    members["device"] = .string(String(repeating: "a", count: 256))
    #expect(try Self.open(try Self.sealed(members)).deviceName.utf8.count == 256)
  }

  @Test("should reject a payload over the size limit")
  func shouldRejectOversizePayload() throws {
    var members = Self.validMembers()
    members["future"] = .string(String(repeating: "x", count: ReplicaManifestCodec.maximumBytes))
    #expect(Self.openError(try Self.sealed(members)) == .tooLarge)
  }

  @Test("should reject a manifest moved to another replica's path")
  func shouldRejectMovedManifest() throws {
    let file = try ReplicaManifestCodec.seal(try Self.golden(), vault: try CodecFixtures.vault(), with: try CodecFixtures.key())
    let error = Self.openError(file, at: VaultPath.manifest(try CodecFixtures.replica(Self.otherText)))
    #expect(error == .file(.authenticationFailed))
  }

  @Test("should reject a payload naming another replica at the right path")
  func shouldRejectPayloadReplicaMismatch() throws {
    var members = Self.validMembers()
    members["replica"] = .string(Self.otherText)
    members["applied"] = [:]
    #expect(Self.openError(try Self.sealed(members)) == .pathMismatch)
  }

  @Test("should reject the wrong vault and an unknown key")
  func shouldRejectWrongVaultAndKey() throws {
    let file = try ReplicaManifestCodec.seal(try Self.golden(), vault: try CodecFixtures.vault(), with: try CodecFixtures.key())
    let ring = CodecFixtures.ring(try CodecFixtures.key())
    let otherVault = try CodecFixtures.vault("vault-two")
    #expect(throws: ReplicaFileError.file(.vaultMismatch(expected: otherVault, found: try CodecFixtures.vault()))) {
      try ReplicaManifestCodec.open(file.data, at: file.key, vault: otherVault, keys: ring)
    }
    let missing = try CodecFixtures.key().id
    #expect(throws: ReplicaFileError.file(.keyUnavailable(missing))) {
      try ReplicaManifestCodec.open(file.data, at: file.key, vault: try CodecFixtures.vault(), keys: { _ in nil })
    }
  }

  @Test("should reject a key that is not a manifest before decrypting")
  func shouldRejectNonManifestKeys() throws {
    let replica = try CodecFixtures.replica(Self.replicaText)
    let tag = try CodecFixtures.tag(Self.headTag)
    let keys = [
      VaultPath.hint,
      VaultPath.segment(replica, first: 1, last: 1, tag: tag),
      VaultPath.basePart(replica, upTo: 1, tag: tag, part: 1, parts: 1),
      try CodecFixtures.objectKey("replicas/\(Self.replicaText)/other"),
    ]
    for key in keys {
      #expect(throws: ReplicaFileError.pathMismatch) {
        try ReplicaManifestCodec.open(Data("not even a vault file".utf8), at: key, vault: try CodecFixtures.vault(), keys: { _ in nil })
      }
    }
  }

  @Test("should never trap on random bytes")
  func shouldSurviveRandomBytes() throws {
    let key = VaultPath.manifest(try CodecFixtures.replica(Self.replicaText))
    let vault = try CodecFixtures.vault()
    let valid = try ReplicaManifestCodec.seal(try Self.golden(), vault: vault, with: try CodecFixtures.key()).data
    let ring = CodecFixtures.ring(try CodecFixtures.key())
    try forAll(iterations: 200) { generator in
      var data = generator.chance(0.5) ? generator.data(count: generator.int(in: 0...200)) : valid
      if data == valid { data[generator.int(in: 0...(data.count - 1))] ^= UInt8(generator.int(in: 1...255)) }
      #expect(throws: ReplicaFileError.self) { try ReplicaManifestCodec.open(data, at: key, vault: vault, keys: ring) }
    }
  }

  @Test("should survive random JSON payloads")
  func shouldSurviveRandomPayloads() throws {
    try forAll(iterations: 200) { generator in
      _ = Self.openError(try Self.sealed(generator.data(count: generator.int(in: 0...120))))
    }
  }
}
