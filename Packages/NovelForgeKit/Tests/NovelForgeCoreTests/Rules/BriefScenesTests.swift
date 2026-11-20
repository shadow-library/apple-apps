import Foundation
import ShadowCore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private func validate(_ json: String) throws -> [String] {
  validateBriefScenes(try parseJSON(json).orThrow("JSON \(json)"))
}

private func scene(_ value: JSONValue) throws -> BriefScene {
  BriefScene(
    summary: try value["summary"].orThrow("summary").string(),
    pov: try value["pov"]?.optionalString(),
    goal: try value["goal"]?.optionalString(),
    obstacle: try value["obstacle"]?.optionalString(),
    turn: try value["turn"]?.optionalString(),
    beats: try value["beats"]?.list().strings(),
    estimatedWords: try value["estimatedWords"]?.optionalInt()
  )
}

struct BriefScenesParityTests {
  @Test func shouldMatchTheReferenceValidationMessagesInTheSameOrderOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("scenes", "validate")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in try validate(try row.at(0).string()) == (try row.at(1).list().strings()) }
    #expect(failed.isEmpty, "messages differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceStringListNormalizationOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("scenes", "stringList")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in normalizeStringList(try row.at(0).list().strings()) == (try row.at(1).list().strings()) }
    #expect(failed.isEmpty, "lists differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceSceneNormalizationOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("scenes", "normalize")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let expected = try row.at(1).list().map(scene)
      return normalizeBriefScenes(try row.at(0).list().map(scene)) == expected
    }
    #expect(failed.isEmpty, "scenes differ for cases \(failed.prefix(10)) of \(failed.count)")
  }
}

struct BriefScenesSpecTests {
  @Test func shouldAcceptScenesWithOrWithoutAPointOfView() throws {
    #expect(try validate(#"[{"summary":"a","pov":"mira"},{"summary":"b","pov":null},{"summary":"c"}]"#).isEmpty)
  }

  @Test func shouldRejectABlankPointOfView() throws {
    #expect(try validate(#"[{"summary":"a","pov":""}]"#) == ["scenes[0].pov must be an entity key or null"])
  }

  @Test func shouldRejectMalformedPlanScenesInTheOrderTheReferenceReportsThem() throws {
    #expect(try validate(#"[{"summary":" ","pov":"mira","mood":"grim"}]"#) == ["scenes[0] has unexpected field 'mood'", "scenes[0].summary must be a non-empty string"])
  }

  @Test func shouldRequireAnArrayOfObjects() throws {
    #expect(try validate("{}") == ["scenes must be an array"])
    #expect(try validate(#"[1,null,[],"x",true]"#).count == 5)
    #expect(try validate("[null]") == ["scenes[0] must be an object"])
  }

  @Test func shouldReportUnexpectedFieldsInJavaScriptKeyOrderWithIntegerKeysFirst() throws {
    #expect(
      try validate(#"[{"zeta":1,"10":1,"2":1,"alpha":1,"summary":"s"}]"#)
        == ["scenes[0] has unexpected field '2'", "scenes[0] has unexpected field '10'", "scenes[0] has unexpected field 'zeta'", "scenes[0] has unexpected field 'alpha'"]
    )
  }

  @Test func shouldTellAMissingDetailFromANullOne() throws {
    #expect(try validate(#"[{"summary":"s"}]"#).isEmpty)
    #expect(
      try validate(#"[{"summary":"s","goal":null,"beats":null,"estimatedWords":null}]"#)
        == ["scenes[0].goal must be a string", "scenes[0].beats must be a list of strings", "scenes[0].estimatedWords must be an integer >= 1"]
    )
  }

  @Test func shouldJudgeEstimatedWordsAsAJavaScriptNumber() throws {
    for accepted in ["1", "1.0", "1e2", "2.0e0", "9007199254740993", "1e21"] { #expect(try validate(#"[{"summary":"s","estimatedWords":\#(accepted)}]"#).isEmpty, "\(accepted)") }
    for rejected in ["0", "-3", "1.5", "0.5", "1e-1", "-0", "1e400", #""5""#, "true", "[]"] {
      #expect(try validate(#"[{"summary":"s","estimatedWords":\#(rejected)}]"#) == ["scenes[0].estimatedWords must be an integer >= 1"], "\(rejected)")
    }
  }

  @Test func shouldTreatJavaScriptWhitespaceAsBlankButNotAZeroWidthSpace() throws {
    #expect(try validate(#"[{"summary":"\u00a0\ufeff"}]"#) == ["scenes[0].summary must be a non-empty string"])
    #expect(try validate(#"[{"summary":"\u200b"}]"#).isEmpty)
    #expect(try validate(#"[{"summary":"\u0085"}]"#).isEmpty)
  }

  @Test func shouldKeepTheLastValueOfADuplicatedKeyAtItsFirstPosition() throws {
    #expect(try validate(#"[{"summary":"","summary":"ok","mood":1,"mood":2}]"#) == ["scenes[0] has unexpected field 'mood'"])
  }

  @Test func shouldTellKeysApartByCodeUnitsNotCanonicalEquivalence() throws {
    #expect(try validate(#"[{"summary":"s","\u00e9":1,"e\u0301":1}]"#).count == 2)
  }

  @Test func shouldTrimDropBlanksAndDeduplicateAStringListKeepingFirstSeenOrder() {
    #expect(normalizeStringList([" a ", "", "b", "a", "\u{A0}", "A", "e\u{301}", "\u{E9}", "\u{E9}"]) == ["a", "b", "A", "e\u{301}", "\u{E9}"])
  }

  @Test func shouldStoreAnOmittedOrBlankPovAsNullAndDropBlankDetails() {
    let normalized = normalizeBriefScenes([BriefScene(summary: " s ", pov: "  ", goal: " ", obstacle: " o ", turn: nil, beats: [" a ", " ", "b"], estimatedWords: 0)])
    #expect(normalized == [BriefScene(summary: "s", pov: nil, goal: nil, obstacle: "o", turn: nil, beats: ["a", "b"], estimatedWords: nil)])
  }

  @Test func shouldDropAnEmptyBeatListAndKeepANegativeWordEstimate() {
    let normalized = normalizeBriefScenes([BriefScene(summary: "s", beats: [" "], estimatedWords: -2)])
    #expect(normalized == [BriefScene(summary: "s", beats: nil, estimatedWords: -2)])
  }

  @Test func shouldEncodeAStoredSceneWithAnExplicitNullPovAndOmitAbsentDetails() throws {
    let data = try JSONEncoder().encode(BriefScene(summary: "s"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object.keys.sorted() == ["pov", "summary"])
    #expect(object["pov"] is NSNull)
    #expect(try JSONDecoder().decode(BriefScene.self, from: data) == BriefScene(summary: "s"))
  }
}

struct BriefScenesPropertyTests {
  private static func randomJSON(_ generator: inout SeededGenerator, depth: Int) -> OrderedJSON {
    switch generator.int(in: 0...(depth > 0 ? 7 : 4)) {
    case 0: return .null
    case 1: return .bool(generator.chance(0.5))
    case 2: return generator.chance(0.5) ? .int(Int64(generator.int(in: -3...3))) : .double(generator.pick(from: [1.5, 1e21, .infinity, .nan, -0.0]))
    case 3: return .string(generator.unicodeString(maxLength: 6))
    case 4: return .string(generator.pick(from: ["", " ", "\u{A0}", "ok"]))
    case 5: return .array((0..<generator.int(in: 0...3)).map { _ in randomJSON(&generator, depth: depth - 1) })
    default:
      let keys = ["summary", "pov", "goal", "obstacle", "turn", "beats", "estimatedWords", "1", "x", generator.unicodeString(maxLength: 3)]
      return .object(OrderedJSONObject((0..<generator.int(in: 0...5)).map { _ in (key: generator.pick(from: keys), value: randomJSON(&generator, depth: depth - 1)) }))
    }
  }

  @Test func shouldNeverCrashOnArbitraryJSONAndAlwaysReportOneMessagePerProblem() throws {
    try forAll(iterations: 1000) { generator in
      let value = Self.randomJSON(&generator, depth: 3)
      let messages = validateBriefScenes(value)
      if case .array(let scenes) = value, scenes.isEmpty { #expect(messages.isEmpty) }
      if case .array = value {} else { #expect(messages == ["scenes must be an array"]) }
    }
  }

  @Test func shouldAcceptEverySceneItNormalizesWhenTheSummaryIsNonBlank() throws {
    try forAll(iterations: 300) { generator in
      let summary = generator.unicodeString(maxLength: 5)
      guard !summary.jsTrim().isEmpty else { return }
      let normalized = normalizeBriefScenes([BriefScene(summary: summary, pov: generator.unicodeString(maxLength: 3), estimatedWords: generator.int(in: 1...500))])
      let data = try JSONEncoder().encode(normalized)
      let text = String(decoding: data, as: UTF8.self)
      #expect(try validate(text).isEmpty, "\(text)")
    }
  }
}
