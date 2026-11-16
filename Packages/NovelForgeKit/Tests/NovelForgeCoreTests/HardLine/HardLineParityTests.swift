import ShadowCore
import Testing

@testable import NovelForgeCore

struct CodedError: ShadowError {
  let code: String

  var errorDescription: String? { code }
}

struct PlainError: Error {}

@Suite("Hard line parity")
struct HardLineParityTests {
  private let fixture: HardLineFixture

  init() throws {
    fixture = try HardLineFixture.load()
  }

  @Test
  func shouldCarryTheReferenceLexiconSourcesAndFlags() {
    let ours: [String: [JSRegex]] = [
      "standalone": HardLineLexicon.standard.standalone, "minor": HardLineLexicon.standard.minor, "sexual": HardLineLexicon.standard.sexual,
      "explicit": HardLineLexicon.standard.explicit,
    ]
    #expect(Set(ours.keys) == Set(fixture.lexicon.keys))
    for (name, expected) in fixture.lexicon {
      let actual = ours[name] ?? []
      #expect(actual.count == expected.count, "\(name)")
      for (regex, pair) in zip(actual, expected) {
        #expect(regex.source.jsEquals(pair[0]) && regex.flags == pair[1], "\(name) \(pair[0])")
      }
    }
  }

  @Test
  func shouldCarryTheReferenceSystemLine() {
    #expect(hardLineSystemLine.jsEquals(fixture.systemLine))
    #expect(fixture.systemLineFindsNothing)
    #expect(findHardLine([hardLineSystemLine], scope: .supplied) == nil)
    #expect(findHardLine([hardLineSystemLine], scope: .background) == nil)
  }

  @Test
  func shouldFindTheSameRuleAsTheReference() {
    for row in fixture.find {
      let actual = row.scope.map { findHardLine(row.texts, scope: $0) } ?? findHardLine(row.texts)
      #expect(actual == row.rule, "\(row.texts)")
    }
  }

  @Test
  func shouldFindTheSameRuleWithACustomLexicon() throws {
    let lexicon = HardLineLexicon(
      standalone: [try JSRegex("zz", flags: "i"), try JSRegex(#"\bq\b"#)],
      minor: [try JSRegex("kid", flags: "i"), try JSRegex(#"\bmini\b"#)],
      sexual: [try JSRegex("spicy"), try JSRegex(#"\bhot\b"#, flags: "i")],
      explicit: [try JSRegex(#"\bexplicit\b"#)]
    )
    for row in fixture.custom {
      #expect(findHardLine(row.texts, scope: row.scope ?? .supplied, lexicon: lexicon) == row.rule, "\(row.texts)")
    }
  }

  @Test
  func shouldScreenTextsAndBuildTheRefusalAsTheReferenceDoes() {
    for row in fixture.hits {
      let hit = screenTexts(row.items)
      #expect(hit == row.hit)
      guard let hit, let expected = row.refusal else {
        #expect(row.refusal == nil)
        continue
      }
      let error = hardLineError(hit)
      #expect(error.code == expected.code)
      #expect((error.errorDescription ?? "").jsEquals(expected.message))
      #expect(expected.status == 422)
    }
  }

  @Test
  func shouldRecogniseARefusalByItsCodeOnly() {
    for row in fixture.refusalKinds {
      let error: (any Error)? =
        switch row.kind {
        case "hard-line": hardLineError(HardLineHit(rule: .standaloneTerm, source: "x", sourceRefs: []))
        case "other-app-error": CodedError(code: "AI_014")
        case "other-app-error-2": CodedError(code: "AI_024")
        case "plain-error": PlainError()
        default: nil
        }
      #expect(isHardLineRefusal(error) == row.refusal, "\(row.kind)")
    }
  }

  @Test
  func shouldDescribeSectionsAsTheReferenceDoes() {
    for row in fixture.describe {
      #expect(describeSection(row.key, sourceRefs: row.refs).jsEquals(row.label), "\(row.key) \(row.refs)")
    }
  }

  @Test
  func shouldClassifyInputsAsTheReferenceDoes() {
    for row in fixture.classification {
      #expect(isClassifiedInput(row.key) == row.classified, "\(row.key)")
      let screens = inputScreens(OrderedJSONObject([(key: row.key, value: .string("x"))]))
      #expect(screens.count == row.screens.count, "\(row.key)")
      for (actual, expected) in zip(screens, row.screens) {
        #expect(actual.scope == expected.scope && actual.source.jsEquals(expected.source), "\(row.key)")
      }
    }
  }

  @Test
  func shouldScopeOutputsByRoleAsTheReferenceDoes() {
    for row in fixture.roles {
      #expect(outputScope(role: row.role) == row.scope, "\(row.role)")
    }
  }

  @Test
  func shouldReadWireMessageTextsAsTheReferenceDoes() {
    for row in fixture.wire {
      #expect(sameStrings(wireMessageTexts(row.messages), row.texts))
    }
  }

  @Test
  func shouldScreenInputsAsTheReferenceDoes() {
    for row in fixture.inputs {
      #expect(sameScreens(inputScreens(row.input), row.screens))
    }
  }

  @Test
  func shouldScreenOutputsAsTheReferenceDoes() {
    for row in fixture.outputs {
      #expect(sameScreens(outputScreens(row.output, role: row.role), row.screens), "\(row.role)")
    }
  }

  @Test
  func shouldScreenSectionsAsTheReferenceDoes() {
    for row in fixture.sections {
      #expect(sameScreens(sectionScreens(row.sections), row.screens))
    }
  }
}
