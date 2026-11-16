import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private func selfCheckReplica(_ text: String) -> ReplicaID {
  guard let replica = ReplicaID(text) else { preconditionFailure("fixture replica id is valid") }
  return replica
}

private func selfCheckTag(_ text: String) -> ContentTag {
  guard let tag = ContentTag(text) else { preconditionFailure("fixture tag is valid") }
  return tag
}

@Suite("ReplicaSelfCheck")
struct ReplicaSelfCheckTests {
  private static let replica = selfCheckReplica("01936f3e-1111-7111-8111-111111111111")
  private static let other = selfCheckReplica("01936f3e-2222-7222-8222-222222222222")
  private static let tagA = selfCheckTag("0123456789abcdef0123456789abcdef")
  private static let tagB = selfCheckTag("fedcba9876543210fedcba9876543210")

  private static let manifest = VaultPath.manifest(replica)
  private static let segmentOne = VaultPath.segment(replica, first: 1, last: 5, tag: tagA)
  private static let segmentTwo = VaultPath.segment(replica, first: 6, last: 9, tag: tagB)
  private static let basePart = VaultPath.basePart(replica, upTo: 5, tag: tagA, part: 1, parts: 2)
  private static let history = ReplicaUploadHistory(segments: [point(5, tagA), point(9, tagB)], bases: [point(5, tagA)])

  private static func point(_ last: Int64, _ tag: ContentTag) -> StreamPoint {
    StreamPoint(last: last, tag: tag)
  }

  private static func key(_ text: String) throws -> ObjectKey {
    try CodecFixtures.objectKey(text)
  }

  private static func input(
    marker: DeviceMarkerStatus = .matches,
    isRetired: Bool = false,
    listed: [ObjectKey] = [manifest, segmentOne, segmentTwo, basePart],
    history: ReplicaUploadHistory = history
  ) -> ReplicaSelfCheckInput {
    ReplicaSelfCheckInput(replica: replica, marker: marker, isRetired: isRetired, listed: listed, history: history)
  }

  private static let unknown = VaultPath.segment(replica, first: 10, last: 12, tag: tagA)

  @Test("should pass a clean replica")
  func shouldPass() {
    #expect(ReplicaSelfCheck.evaluate(Self.input()) == .pass)
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [], history: ReplicaUploadHistory())) == .pass)
  }

  @Test("should apply the rules in order")
  func shouldApplyRulesInOrder() {
    let dirty = [Self.manifest, Self.unknown]
    let cases: [(ReplicaSelfCheckInput, ReplicaSelfCheckVerdict)] = [
      (Self.input(marker: .unreadable, isRetired: true, listed: dirty), .postpone),
      (Self.input(marker: .missing, isRetired: true, listed: dirty), .remint(.markerMissing)),
      (Self.input(marker: .other(Self.other), isRetired: true, listed: dirty), .remint(.markerNamesOther(Self.other))),
      (Self.input(marker: .matches, isRetired: true, listed: dirty), .remint(.retired)),
      (Self.input(marker: .matches, isRetired: false, listed: dirty), .remint(.unknownSegment(Self.point(12, Self.tagA)))),
      (Self.input(marker: .matches, isRetired: false, listed: [Self.manifest]), .pass),
    ]
    for (input, verdict) in cases { #expect(ReplicaSelfCheck.evaluate(input) == verdict) }
  }

  @Test("should not fail on remembered files the listing does not show")
  func shouldIgnoreStaleListing() {
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [Self.manifest])) == .pass)
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [Self.segmentTwo])) == .pass)
  }

  @Test("should pass a listed segment that the history remembers deleting")
  func shouldPassRememberedSegment() {
    let history = ReplicaUploadHistory(segments: [Self.point(5, Self.tagA)])
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [Self.segmentOne], history: history)) == .pass)
  }

  @Test("should find one unknown segment among many known ones")
  func shouldFindUnknownSegment() throws {
    var segments: Set<StreamPoint> = []
    var listed = [Self.manifest]
    for index in 0..<40 {
      let first = Int64(index * 10 + 1)
      let tag = try CodecFixtures.tag(String(repeating: String(index % 10), count: 32))
      segments.insert(Self.point(first + 9, tag))
      listed.append(VaultPath.segment(Self.replica, first: first, last: first + 9, tag: tag))
    }
    let stranger = VaultPath.segment(Self.replica, first: 401, last: 410, tag: Self.tagB)
    let verdict = ReplicaSelfCheck.evaluate(Self.input(listed: listed + [stranger], history: ReplicaUploadHistory(segments: segments)))
    #expect(verdict == .remint(.unknownSegment(Self.point(410, Self.tagB))))
  }

  @Test("should match a segment by its last sequence and tag")
  func shouldMatchByLastAndTag() {
    let history = ReplicaUploadHistory(segments: [Self.point(12, Self.tagB)])
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [Self.unknown], history: history)) == .remint(.unknownSegment(Self.point(12, Self.tagA))))
  }

  @Test("should flag a base part whose upTo and tag are unknown")
  func shouldFlagUnknownBase() {
    let wrongTag = VaultPath.basePart(Self.replica, upTo: 5, tag: Self.tagB, part: 1, parts: 1)
    let wrongUpTo = VaultPath.basePart(Self.replica, upTo: 6, tag: Self.tagA, part: 1, parts: 1)
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [wrongTag])) == .remint(.unknownBase(Self.point(5, Self.tagB))))
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [wrongUpTo])) == .remint(.unknownBase(Self.point(6, Self.tagA))))
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [Self.basePart])) == .pass)
  }

  @Test("should flag keys that are not this replica's files")
  func shouldFlagForeignKeys() throws {
    let blob = VaultPath.blobPart(name: String(repeating: "ab", count: 32), part: 1, parts: 1)
    let foreign: [ObjectKey] = [
      try Self.key("replicas/\(Self.replica)/seg/garbage"),
      try Self.key("replicas/\(Self.replica)/notes.txt"),
      try Self.key("replicas/\(Self.replica)/seg/000000000001-000000000005-\(Self.tagA)/extra"),
      blob,
      try Self.key("replicas/\(Self.replica)x/seg/000000000001-000000000005-\(Self.tagA)"),
      try Self.key("replicas/\(Self.replica)x/manifest"),
      try Self.key("replicas/\(Self.replica)/manifest/extra"),
      try Self.key("replicas/\(Self.replica)/seg/000000000001-000000000005-\(Self.tagA)/extra"),
      try Self.key("replicas/\(Self.replica)/base/000000000005-\(Self.tagA)"),
      VaultPath.hint,
      VaultPath.manifest(Self.other),
      VaultPath.segment(Self.other, first: 1, last: 5, tag: Self.tagA),
    ]
    for key in foreign { #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [Self.manifest, key])) == .remint(.unknownObject(key))) }
  }

  @Test("should report the smallest failing key by bytes")
  func shouldReportSmallestKey() throws {
    let garbage = try Self.key("replicas/\(Self.replica)/zzz")
    let baseKey = VaultPath.basePart(Self.replica, upTo: 99, tag: Self.tagA, part: 1, parts: 1)
    let all = [garbage, Self.unknown, baseKey]
    for listed in [all, all.reversed()] {
      #expect(ReplicaSelfCheck.evaluate(Self.input(listed: listed)) == .remint(.unknownBase(Self.point(99, Self.tagA))))
    }
    #expect(ReplicaSelfCheck.evaluate(Self.input(listed: [garbage, Self.unknown])) == .remint(.unknownSegment(Self.point(12, Self.tagA))))
  }

  private static func adversarialListing(_ generator: inout SeededGenerator) throws -> [ObjectKey] {
    var keys: [ObjectKey] = []
    for _ in 0..<generator.int(in: 0...12) {
      let tag = try CodecFixtures.tag(&generator)
      switch generator.int(in: 0...8) {
      case 0: keys.append(manifest)
      case 1: keys.append(segmentOne)
      case 2: keys.append(VaultPath.segment(replica, first: 1, last: 5, tag: tag))
      case 3: keys.append(VaultPath.segment(replica, first: 1, last: 9, tag: tagB))
      case 4: keys.append(VaultPath.basePart(replica, upTo: 5, tag: tag, part: 1, parts: 1))
      case 5: keys.append(VaultPath.basePart(replica, upTo: Int64(generator.int(in: 0...9)), tag: tagA, part: 1, parts: 1))
      case 6: keys.append(VaultPath.segment(other, first: 1, last: 5, tag: tag))
      case 7: keys.append(try key("replicas/\(replica)/seg/\(CodecFixtures.hex(&generator, count: 8))"))
      default: keys.append(VaultPath.blobPart(name: CodecFixtures.hex(&generator, count: 64), part: 1, parts: 1))
      }
    }
    return keys
  }

  @Test("should give the same verdict for any listing order")
  func shouldBeDeterministic() throws {
    var failing = 0
    try forAll(iterations: 300) { generator in
      let listed = try Self.adversarialListing(&generator)
      let verdict = ReplicaSelfCheck.evaluate(Self.input(listed: listed))
      if verdict != .pass { failing += 1 }
      #expect(ReplicaSelfCheck.evaluate(Self.input(listed: generator.shuffled(listed))) == verdict)
      #expect(ReplicaSelfCheck.evaluate(Self.input(listed: listed.reversed())) == verdict)
      #expect(ReplicaSelfCheck.evaluate(Self.input(listed: listed + listed)) == verdict)
    }
    #expect(failing > 50)
  }
}
