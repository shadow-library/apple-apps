import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private func parsed(_ text: String) throws -> OrderedJSON {
  try parseJSON(text).orThrow("JSON \(text)")
}

private func record(_ text: String, names: [String] = [], aliases: String = "") throws -> OrderedJSONObject {
  guard case .object(let object) = try parsed(text) else { throw FixtureShapeError(description: "not an object: \(text)") }
  let table = Dictionary(uniqueKeysWithValues: zip(aliases.map { String($0) }, names))
  return OrderedJSONObject(object.entries.map { (key: table[$0.key] ?? $0.key, value: $0.value) })
}

private func volume(_ text: String) throws -> String { volumeContentHash(try record(text)) }
private func brief(_ text: String) throws -> String { briefContentHash(try record(text)) }

struct ContentHashParityTests {
  private func checkPairs(_ key: String, hash: (OrderedJSONObject) -> String) throws {
    let names = try RuleFixture.section("hash", "aliasNames").strings()
    let aliases = try RuleFixture.load("hash")["aliases"].orThrow("aliases").string()
    let cases = try RuleFixture.section("hash", key)
    #expect(cases.count >= 300)
    #expect(try cases.contains { try $0.at(2).int() == 1 } && cases.contains { try $0.at(2).int() == 0 })
    let failed = try mismatches(cases) { row in
      let left = hash(try record(try row.at(0).string(), names: names, aliases: aliases))
      let right = hash(try record(try row.at(1).string(), names: names, aliases: aliases))
      return (left == right) == (try row.at(2).int() == 1)
    }
    #expect(failed.isEmpty, "\(key) hash equality differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldHashVolumesEqualExactlyWhenTheReferenceDoes() throws {
    try checkPairs("volume", hash: volumeContentHash)
  }

  @Test func shouldHashBriefsEqualExactlyWhenTheReferenceDoes() throws {
    try checkPairs("brief", hash: briefContentHash)
  }

  @Test func shouldHashHandWrittenRecordPairsEqualExactlyWhenTheReferenceDoes() throws {
    let cases = try RuleFixture.section("hash", "raw")
    #expect(cases.count >= 40)
    let failed = try mismatches(cases) { row in
      let hash = try row.at(0).int() == 0 ? volumeContentHash : briefContentHash
      return (hash(try record(try row.at(1).string())) == hash(try record(try row.at(2).string()))) == (try row.at(3).int() == 1)
    }
    #expect(failed.isEmpty, "raw pairs differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldHashBibleDocumentsEqualExactlyWhenTheReferenceDoes() throws {
    let cases = try RuleFixture.section("hash", "doc")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      func hash(_ front: Int, _ body: Int) throws -> String {
        computeBibleDocHash(frontmatter: try row.at(front).optionalString().map(parsed), body: try row.at(body).optionalString().map(parsed))
      }
      return (try hash(0, 1) == (try hash(2, 3))) == (try row.at(4).int() == 1)
    }
    #expect(failed.isEmpty, "document hash equality differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldHashGenericContentEqualExactlyWhenTheReferenceDoes() throws {
    let cases = try RuleFixture.section("hash", "content")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      (computeContentHash(try record(try row.at(0).string())) == computeContentHash(try record(try row.at(1).string()))) == (try row.at(2).int() == 1)
    }
    #expect(failed.isEmpty, "content hash equality differs for cases \(failed.prefix(10)) of \(failed.count)")
  }
}

struct ContentHashSpecTests {
  @Test func shouldHashOnlyTheContractedVolumeFields() throws {
    let base = try volume(#"{"volumeKey":"v1","ordinal":1,"title":"Ascent"}"#)
    #expect(base.count == 64 && base.allSatisfy(\.isHexDigit))
    #expect(try volume(#"{"volumeKey":"v1","ordinal":1,"title":"Ascent","draftNotes":"ignored","revision":7}"#) == base)
    #expect(try volume(#"{"volumeKey":"v1","ordinal":1,"title":"Descent"}"#) != base)
  }

  @Test func shouldTreatAnAbsentVolumeFieldAndAnExplicitNullIdentically() throws {
    #expect(try volume(#"{"volumeKey":"v1"}"#) == volume(#"{"volumeKey":"v1","objective":null}"#))
  }

  @Test func shouldHashABriefWhosePlanFieldsHoldTheirDefaultsTheSameAsOneHashedBeforeTheyExisted() throws {
    let defaults = #"{"chapter":3,"body":"b","direction":null,"contentMode":null,"scenes":null,"claimedMilestones":null,"isEnding":false}"#
    #expect(try brief(defaults) == brief(#"{"chapter":3,"body":"b"}"#))
  }

  @Test func shouldChangeABriefHashWhenAnyPlanFieldLeavesItsDefault() throws {
    let base = try brief(#"{"chapter":3,"body":"b"}"#)
    for field in [#""direction":"d""#, #""contentMode":"unrestricted""#, #""scenes":[]"#, #""claimedMilestones":["m"]"#, #""isEnding":true"#] {
      #expect(try brief(#"{"chapter":3,"body":"b",\#(field)}"#) != base)
    }
  }

  @Test func shouldHashAVolumeNotYetStartedTheSameAsOneHashedBeforeVolumesHadAState() throws {
    #expect(try volume(#"{"volumeKey":"v1","state":"not_started"}"#) == volume(#"{"volumeKey":"v1"}"#))
    #expect(try volume(#"{"volumeKey":"v1","state":"active"}"#) != volume(#"{"volumeKey":"v1"}"#))
  }

  @Test func shouldHashOnlyTheContractedBriefFields() throws {
    let base = try brief(#"{"chapter":1,"body":"b"}"#)
    #expect(try brief(#"{"chapter":1,"body":"b","updatedAt":"1970-01-01T00:00:00.000Z"}"#) == base)
    #expect(try brief(#"{"chapter":2,"body":"b"}"#) != base)
  }

  @Test func shouldChangeABriefHashWhenOnlyThePovOrTheGuidanceChanges() throws {
    let base = try brief(#"{"chapter":1,"body":"b"}"#)
    #expect(try brief(#"{"chapter":1,"body":"b","pov":"hero"}"#) != base)
    #expect(try brief(#"{"chapter":1,"body":"b","guidance":"slow down"}"#) != base)
  }

  @Test func shouldTreatNullAndAbsentBibleDocumentInputsIdentically() throws {
    #expect(computeBibleDocHash(frontmatter: nil, body: .string("body")) == computeBibleDocHash(frontmatter: .null, body: .string("body")))
  }

  @Test func shouldBeSensitiveToFrontmatterKeyOrder() throws {
    let a = computeBibleDocHash(frontmatter: try parsed(#"{"title":"Promise","status":"draft"}"#), body: .string("body"))
    let b = computeBibleDocHash(frontmatter: try parsed(#"{"status":"draft","title":"Promise"}"#), body: .string("body"))
    #expect(a != b)
  }

  @Test func shouldIgnoreKeyOrderInCanonicalizedContentAtEveryDepth() throws {
    #expect(try computeContentHash(record(#"{"a":{"x":1,"y":[{"p":1,"q":2}]},"b":2}"#)) == computeContentHash(record(#"{"b":2,"a":{"y":[{"q":2,"p":1}],"x":1}}"#)))
  }

  @Test func shouldKeepStringsThatDifferOnlyByNormalizationOrCaseApart() throws {
    let nfc = try volume(#"{"volumeKey":"v","title":"é"}"#)
    #expect(try volume(#"{"volumeKey":"v","title":"é"}"#) != nfc)
    #expect(try volume(#"{"volumeKey":"v","title":"É"}"#) != nfc)
  }

  @Test func shouldHashAFractionalAndAnIntegralSpellingOfTheSameNumberEqual() throws {
    #expect(try volume(#"{"volumeKey":"v","ordinal":1}"#) == volume(#"{"volumeKey":"v","ordinal":1.0e0}"#))
  }
}

struct ContentHashPropertyTests {
  @Test func shouldLeaveAVolumeHashUnchangedByFieldsTheReferenceIgnores() throws {
    try forAll(iterations: 200) { generator in
      let title = generator.unicodeString(maxLength: 6)
      let base = OrderedJSONObject([(key: "volumeKey", value: .string("v1")), (key: "title", value: .string(title))])
      let noisy = OrderedJSONObject([
        (key: "revision", value: .int(Int64(generator.int(in: 0...9)))),
        (key: "title", value: .string(title)),
        (key: generator.asciiString(maxLength: 6) + "_ignored", value: .null),
        (key: "volumeKey", value: .string("v1")),
        (key: "state", value: .string("not_started")),
      ])
      #expect(volumeContentHash(base) == volumeContentHash(noisy))
    }
  }

  @Test func shouldChangeAVolumeHashWhenAHashedStringChanges() throws {
    try forAll(iterations: 200) { generator in
      let first = generator.unicodeString(maxLength: 6)
      let second = first + generator.unicodeString(maxLength: 3) + "x"
      let a = OrderedJSONObject([(key: "title", value: .string(first))])
      let b = OrderedJSONObject([(key: "title", value: .string(second))])
      #expect(volumeContentHash(a) != volumeContentHash(b))
    }
  }
}
