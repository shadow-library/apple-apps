import ShadowCore
import Testing

@testable import NovelForgeCore

@Suite("Hard line")
struct HardLineSpecTests {
  @Test
  func shouldRefuseEveryStandaloneTermOnItsOwn() {
    for term in ["lolicon", "shotacon", "loli", "shota", "csam", "child porn", "child pornography", "pedophilic", "paedophilic", "LOLI"] {
      #expect(findHardLine([term], scope: .background) == .standaloneTerm, "\(term)")
    }
  }

  @Test
  func shouldPairAMinorTermWithTheScopeOfTheText() {
    #expect(findHardLine(["a child, sexual"]) == .minorWithSexualContent)
    #expect(findHardLine(["a child, sexual"], scope: .background) == nil)
    #expect(findHardLine(["a child, orgasm"], scope: .background) == .minorWithExplicitAct)
    #expect(findHardLine(["a child, sex"], scope: .background) == nil)
  }

  @Test
  func shouldKeepTheTwoHalvesOfAPairingInOneSegment() {
    #expect(findHardLine(["a child. sex"]) == nil)
    #expect(findHardLine(["a child\nsex"]) == nil)
    #expect(findHardLine(["\"a child\", \"sex\""]) == nil)
    #expect(findHardLine(["a child\u{2028}sex"]) == .minorWithSexualContent)
    #expect(findHardLine(["a child\rsex"]) == .minorWithSexualContent)
    #expect(findHardLine(["child", "sex"]) == nil)
  }

  @Test
  func shouldTreatWordBoundariesAsAsciiOnly() {
    #expect(findHardLine(["éloli"]) == .standaloneTerm)
    #expect(findHardLine(["loliá"]) == .standaloneTerm)
    #expect(findHardLine(["loli_"]) == nil)
    #expect(findHardLine(["ſchoolgirl sex"]) == nil)
    #expect(findHardLine(["\u{212A}id sex"]) == nil)
  }

  @Test
  func shouldReadAgesBelowEighteenOnly() {
    #expect(findHardLine(["17 yo sex"]) == .minorWithSexualContent)
    #expect(findHardLine(["17\u{00A0}yo sex"]) == .minorWithSexualContent)
    #expect(findHardLine(["18 yo sex"]) == nil)
    #expect(findHardLine(["117 yo sex"]) == nil)
    #expect(findHardLine(["aged seventeen sex"]) == .minorWithSexualContent)
    #expect(findHardLine(["age of eighteen sex"]) == nil)
  }

  @Test
  func shouldBuildTheRefusalFromTheHit() {
    let error = hardLineError(HardLineHit(rule: .minorWithExplicitAct, source: "Chapter 4's summary", sourceRefs: ["chapter:4"]))
    #expect(error.code == "AI_015")
    #expect(
      error.errorDescription
        == "This request was declined before it reached a model: Chapter 4's summary appears to involve sexual content with a minor, which Novel Forge never writes in any mode"
    )
    #expect(error == .declined(source: "Chapter 4's summary", rule: .minorWithExplicitAct, sourceRefs: ["chapter:4"]))
  }

  @Test
  func shouldRecogniseARefusalByCodeAlone() {
    #expect(isHardLineRefusal(CodedError(code: "AI_015")))
    #expect(!isHardLineRefusal(CodedError(code: "AI_014")))
    #expect(!isHardLineRefusal(PlainError()))
    #expect(!isHardLineRefusal(nil))
  }

  @Test
  func shouldStopARequestThroughAGuard() throws {
    let guardrail = RequestGuard(
      screen: { messages throws(HardLineError) in
        let items = wireMessageTexts(messages).map { ScreenedText(text: $0, scope: .supplied, source: "The request") }
        if let hit = screenTexts(items) { throw hardLineError(hit) }
      },
      systemLine: hardLineSystemLine
    )
    try guardrail.screen([WireMessage(content: .text("a quiet day"))])
    #expect(throws: HardLineError.declined(source: "The request", rule: .minorWithSexualContent, sourceRefs: [])) {
      try guardrail.screen([WireMessage(content: .parts([HardLineContentPart(text: "a child"), HardLineContentPart(text: "sex")])), WireMessage(content: .text("a child sex"))])
    }
  }

  @Test
  func shouldJoinContentPartsWithNewlinesAndSkipThoseWithoutText() {
    let content = HardLineContent.parts([HardLineContentPart(text: "a"), HardLineContentPart(text: nil), HardLineContentPart(text: "b")])
    #expect(wireMessageTexts([WireMessage(content: content), WireMessage(content: .other), WireMessage(content: .parts([]))]) == ["a\n\nb", "", ""])
  }

  @Test
  func shouldReadContentFromJSONShapes() {
    #expect(HardLineContent(json: nil) == .other)
    #expect(HardLineContent(json: .int(5)) == .other)
    #expect(HardLineContent(json: .string("x")) == .text("x"))
    let parts = OrderedJSON.array([
      .object(OrderedJSONObject([(key: "text", value: .string("t"))])), .object(OrderedJSONObject([(key: "text", value: .int(5))])), .array([.string("x")]),
    ])
    #expect(HardLineContent(json: parts) == .parts([HardLineContentPart(text: "t"), HardLineContentPart(text: nil), HardLineContentPart(text: nil)]))
  }

  @Test
  func shouldTakeTheContentOfMessageLikeItemsAndRecurseIntoOtherValues() {
    let message = OrderedJSON.object(OrderedJSONObject([(key: "role", value: .string("user")), (key: "content", value: .string("hi"))]))
    let nested = OrderedJSON.array([message, .array([message]), .object(OrderedJSONObject([(key: "b", value: .string("deep"))])), .int(5), .null])
    #expect(valueTexts(nested) == ["hi", "hi", "deep"])
  }

  @Test
  func shouldWalkObjectValuesWithIntegerKeysFirst() {
    let object = OrderedJSON.object(
      OrderedJSONObject([(key: "b", value: .string("b")), (key: "10", value: .string("ten")), (key: "2", value: .string("two")), (key: "a", value: .string("a"))]))
    #expect(valueTexts(object) == ["two", "ten", "b", "a"])
  }

  @Test
  func shouldHoldUnknownInputsToTheFullRule() {
    let screens = inputScreens(OrderedJSONObject([(key: "mystery_key", value: .string("x"))]))
    #expect(screens == [ScreenedText(text: "x", scope: .supplied, source: "The request")])
  }

  @Test
  func shouldTreatPrototypeNamesAsUnclassifiedInputsUnlikeTheReference() throws {
    let fixture = try HardLineFixture.load()
    #expect(fixture.prototypeKeys.count == 12)
    for row in fixture.prototypeKeys {
      #expect(row.referenceClassified, "\(row.key)")
      #expect(!isClassifiedInput(row.key), "\(row.key)")
      let screens = inputScreens(OrderedJSONObject([(key: row.key, value: .string("x"))]))
      #expect(screens == [ScreenedText(text: "x", scope: .supplied, source: "The request")], "\(row.key)")
      #expect(describeSection("characters", sourceRefs: ["\(row.key):v"]) == "The story context's characters section", "\(row.key)")
    }
    #expect(Set(fixture.prototypeKeys.map(\.referenceOutcome)).contains("throws"))
  }

  @Test
  func shouldScreenABareStringContentPartAsItsOwnTextAndReadOtherPrimitivesAsEmptyWhereTheReferenceThrows() throws {
    let fixture = try HardLineFixture.load()
    #expect(!fixture.wireDeviations.isEmpty)
    for row in fixture.wireDeviations {
      #expect(sameStrings(wireMessageTexts(row.messages), row.texts))
    }
    let primitive = OrderedJSON.array([.string("child sex"), .null, .int(5)])
    #expect(wireMessageTexts([WireMessage(content: HardLineContent(json: primitive))]) == ["child sex\n\n"])
  }

  @Test
  func shouldRefuseBareStringContentPartsOnEveryPath() {
    let cases: [(text: String, supplied: HardLineRule, background: HardLineRule?)] = [
      ("lolicon", .standaloneTerm, .standaloneTerm),
      ("child sex", .minorWithSexualContent, nil),
      ("child orgasm", .minorWithSexualContent, .minorWithExplicitAct),
    ]
    for (text, supplied, background) in cases {
      let content = OrderedJSON.array([.string(text)])
      let message = OrderedJSON.object(OrderedJSONObject([(key: "content", value: content)]))
      let history = inputScreens(OrderedJSONObject([(key: "history", value: .array([message]))]))
      #expect(history.map(\.text) == [text])
      #expect(screenTexts(history) == (background.map { HardLineHit(rule: $0, source: "The earlier conversation", sourceRefs: []) }))
      let message2 = inputScreens(OrderedJSONObject([(key: "userMessage", value: .array([message]))]))
      #expect(screenTexts(message2)?.rule == supplied)
      let creative = outputScreens(.array([message]), role: "chat")
      #expect(screenTexts(creative)?.rule == supplied)
      let derived = outputScreens(.array([message]), role: "summary")
      #expect(screenTexts(derived)?.rule == background)
      let wire = wireMessageTexts([WireMessage(content: HardLineContent(json: content))]).map { ScreenedText(text: $0, scope: .supplied, source: "The request") }
      #expect(screenTexts(wire)?.rule == supplied)
    }
  }

  @Test
  func shouldMatchWithoutRemainingStateWhenALexiconRegexIsGlobal() throws {
    let lexicon = HardLineLexicon(standalone: [try JSRegex("zz", flags: "g")], minor: [], sexual: [], explicit: [])
    #expect(findHardLine(["zz"], lexicon: lexicon) == .standaloneTerm)
    #expect(findHardLine(["zz"], lexicon: lexicon) == .standaloneTerm)
  }

  @Test
  func shouldScreenTheBriefSectionAsSuppliedAndTheRestAsBackground() {
    let sections = [ContextSection(key: "brief", rendered: "a", sourceRefs: ["chapter:2"]), ContextSection(key: "plot_threads", rendered: "b", sourceRefs: [])]
    #expect(
      sectionScreens(sections) == [
        ScreenedText(text: "a", scope: .supplied, source: "Chapter 2's plan", sourceRefs: ["chapter:2"]),
        ScreenedText(text: "b", scope: .background, source: "The story context's plot threads section", sourceRefs: []),
      ]
    )
  }

  @Test
  func shouldStopAtTheFirstScreenedItemThatTrips() {
    let items = [
      ScreenedText(text: "fine", scope: .supplied, source: "A"),
      ScreenedText(text: "loli", scope: .background, source: "B", sourceRefs: ["fact:x"]),
      ScreenedText(text: "csam", scope: .supplied, source: "C"),
    ]
    #expect(screenTexts(items) == HardLineHit(rule: .standaloneTerm, source: "B", sourceRefs: ["fact:x"]))
    #expect(screenTexts([]) == nil)
  }
}
