import Foundation
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let rawPayload =
  #"{"changeSet":[{"op":"upsert","target":"bible:x","value":{"reply":"not me","note":"contains { and [ and \"reply\" text"}}],"#
  + #""lookups":[{"tool":"search_lore","args":{"q":"a}b]c","n":42,"ok":true,"none":null}}],"#
  + #""reply":"Hello \"world\"!\nLine two\twith tab, café 😀 and \\backslash\\ end."}"#

private let expectedReply = "Hello \"world\"!\nLine two\twith tab, café 😀 and \\backslash\\ end."

private let changeElements = [
  #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara \"the Quiet\"","body":"Braces { and } and brackets [ ] and a \\ backslash"}"#,
  #"{"op":"bible_document.upsert","section":"world","slug":"tides","frontmatter":{"title":"Tides","tags":["sea",{"nested":[1,2,{"deep":"}]"}]}]}}"#,
  #"{"op":"promise.create","kind":"mystery","key":"who-rang","label":"Who rang the bell? — café 😀","openedChapter":3,"done":null,"flag":true}"#,
]

private let changesAfterReply = #"{"reply":"Here are the changes.","changeSet":[\#(changeElements.joined(separator: ","))],"question":"Anything else?"}"#
private let changesBeforeReply = #"{"changeSet":[\#(changeElements.joined(separator: ","))],"lookups":[],"reply":"Changes first."}"#

private func utf16Count(_ text: String) -> Int {
  text.utf16.count
}

private func offset(of needle: String, in text: String) -> Int {
  guard let range = text.range(of: needle) else { return -1 }
  return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
}

private func sources(_ result: ScanResult) -> [String] {
  result.elements.map(\.source)
}

private func expectElements(_ result: ScanResult, equal expected: [String], sourceLocation: SourceLocation = #_sourceLocation) {
  let actual = sources(result)
  #expect(actual.count == expected.count, sourceLocation: sourceLocation)
  #expect(zip(actual, expected).allSatisfy { jsonEqual($0, $1) }, sourceLocation: sourceLocation)
}

struct ReplyScannerReferenceSpecTests {
  @Test func shouldEmitTheWholeReplyWhenPushedAsASingleChunk() {
    let result = scan(rawPayload)
    #expect(result.reply == expectedReply)
    #expect(result.state == .completed)
  }

  @Test func shouldNotEmitTextFromAReplyKeyNestedInsideChangeSet() {
    let result = scan(rawPayload, sizes: [utf16Count(rawPayload)])
    #expect(!result.reply.contains("not me"))
    #expect(result.reply == expectedReply)
  }

  @Test func shouldSkipStringsContainingBracesBracketsEscapedQuotesAndTheLiteralTextReply() {
    let result = scan(rawPayload, sizes: [utf16Count(rawPayload)])
    #expect(result.state == .completed)
    #expect(result.reply == expectedReply)
  }

  @Test func shouldDecodeEscapesIncludingASurrogatePair() {
    #expect(expectedReply.contains("\n"))
    #expect(expectedReply.contains("\t"))
    #expect(scan(rawPayload).reply.contains("\"world\""))
    #expect(scan(rawPayload).reply.contains("café"))
    #expect(scan(rawPayload).reply.contains("😀"))
    #expect(scan(rawPayload).reply.contains("\\backslash\\"))
  }

  @Test func shouldDecodeSolidusBackspaceAndFormFeedEscapes() {
    #expect(scan(#"{"reply":"a\/b\bc\fd"}"#).reply == "a/b\u{08}c\u{0C}d")
  }

  @Test func shouldStayAwaitingTheReplyWhenTheReplyKeyNeverArrives() {
    let result = scan(#"{"changeSet":[{"op":"upsert","target":"bible:x","value":{"body":"no reply here"}}]}"#)
    #expect(result.reply == "")
    #expect(result.state == .awaitingReply)
  }

  @Test func shouldTolerateAMarkdownFenceAndLeadingProseBeforeTheJSONObject() {
    let result = scan("Sure, here you go:\n```json\n" + rawPayload + "\n```")
    #expect(result.reply == expectedReply)
    #expect(result.state == .completed)
  }

  @Test func shouldStopEmittingAfterTheClosingQuoteOfTheReplyValue() {
    #expect(scan(rawPayload + "\n\nignored trailer text {not json} \"reply\": \"fake\"").reply == expectedReply)
  }

  @Test func shouldEmitOnlyWhatWasDecodedBeforeAStreamTruncatedMidValue() {
    let cut = String(rawPayload.prefix(upTo: rawPayload.range(of: #"é"#)?.lowerBound ?? rawPayload.endIndex))
    let result = scan(cut + "more text that never closes the string", sizes: [utf16Count(cut)])
    #expect(expectedReply.hasPrefix(scan(cut).reply))
    #expect(result.state == .replyFound)
  }

  @Test func shouldStayAwaitingTheReplyWhenTruncatedBeforeTheReplyKeyIsReached() {
    let cut = String(rawPayload.prefix(upTo: rawPayload.range(of: #""lookups""#)?.lowerBound ?? rawPayload.endIndex))
    #expect(scan(cut).state == .awaitingReply)
  }

  @Test func shouldSplitAKeyAcrossAChunkBoundaryMidKey() {
    #expect(scan(rawPayload, sizes: [offset(of: #""reply""#, in: rawPayload) + 3]).reply == expectedReply)
  }

  @Test func shouldSplitAtABoundaryBetweenTheKeyAndTheColon() {
    let index = rawPayload.range(of: #""reply":"Hello"#).map { rawPayload.utf16.distance(from: rawPayload.utf16.startIndex, to: $0.lowerBound) + 7 } ?? 0
    #expect(scan(rawPayload, sizes: [index]).reply == expectedReply)
  }

  @Test func shouldSplitInsideAnEscapeSequenceBetweenTheBackslashAndTheLetter() {
    #expect(scan(rawPayload, sizes: [offset(of: #"\nLine"#, in: rawPayload) + 1]).reply == expectedReply)
  }

  @Test func shouldSplitAUnicodeEscapeIntoOneCharacterPerChunk() {
    #expect(scan(rawPayload, sizes: [offset(of: #"é"#, in: rawPayload)] + Array(repeating: 1, count: 6)).reply == expectedReply)
  }

  @Test func shouldSplitASurrogatePairEscapeAcrossSeparatePushes() {
    #expect(scan(rawPayload, sizes: [offset(of: #"\ud83d"#, in: rawPayload), 6, utf16Count(rawPayload)]).reply == expectedReply)
  }

  @Test func shouldProduceIdenticalOutputWhenThePayloadIsFedOneCharacterAtATime() {
    let result = scan(rawPayload, sizes: Array(repeating: 1, count: utf16Count(rawPayload)))
    #expect(result.reply == expectedReply)
    #expect(result.state == .completed)
  }

  @Test func shouldProduceIdenticalOutputForEveryTwoChunkSplitOfThePayload() {
    for result in scan(rawPayload, everyTwoChunkSplit: true) {
      #expect(result.reply == expectedReply)
      #expect(result.state == .completed)
    }
  }

  @Test func shouldProduceIdenticalOutputForThirtyRandomizedChunkingsOfTheSamePayload() {
    var generator = SeededGenerator(seed: 1_234_567)
    for _ in 0..<30 {
      let sizes = (0..<utf16Count(rawPayload)).map { _ in generator.int(in: 1...4) }
      let result = scan(rawPayload, sizes: sizes)
      #expect(result.reply == expectedReply)
      #expect(result.state == .completed)
    }
  }

  @Test func shouldResyncAfterABraceInsideLeadingProse() {
    let result = scan("Here is the JSON {as requested}:\n{\"reply\":\"hi\"}")
    #expect(result.reply == "hi")
    #expect(result.state == .completed)
  }

  @Test func shouldResyncAcrossChunkBoundariesWhenTheBraceBearingProseIsSplitMidChunk() {
    let noisy = "Here is the JSON {as requested}:\n{\"reply\":\"hi\"}"
    let result = scan(noisy, sizes: [18, 1, 1, 1, 1, 1, 1, 1, utf16Count(noisy)])
    #expect(result.reply == "hi")
    #expect(result.state == .completed)
  }

  @Test func shouldNeverMistakeAVeryLongUnterminatedKeyForReplyNorBufferItUnbounded() {
    var scanner = ReplyScanner()
    _ = scanner.consume("{\"")
    let started = ContinuousClock.now
    _ = scanner.consume(String(repeating: "x", count: 100_000))
    #expect(ContinuousClock.now - started < .seconds(10))
    #expect(scanner.consume("\":\"value\",\"reply\":\"hi\"}") == [.reply("hi")])
    #expect(scanner.state == .completed)
  }

  @Test func shouldNotTreatAKeyMerelyStartingWithTheSameLettersAsReply() {
    #expect(scan(#"{"replying":"not the field","reply":"the field"}"#).reply == "the field")
  }

  @Test func shouldEmitOnlyWellFormedTextFromEveryPushEvenWhenASurrogatePairIsSplit() {
    let payload = "{\"reply\":\"hi 😀!\"}"
    let result = scan(chunks: payload.utf16.map { [$0] })
    #expect(result.reply == "hi 😀!")
    #expect(!result.replyPieces.contains { $0.contains("\u{FFFD}") })
  }

  @Test func shouldNotLeakATopLevelReplyValueThatTurnsOutToBeAnArray() {
    let result = scan(#"{"reply":["leak"],"x":1}"#)
    #expect(result.reply == "")
    #expect(result.state == .awaitingReply)
  }

  @Test func shouldNotLeakATopLevelReplyValueThatTurnsOutToBeAnObject() {
    let result = scan(#"{"reply":{"reply":"leak"},"x":1}"#)
    #expect(result.reply == "")
    #expect(result.state == .awaitingReply)
  }

  @Test func shouldNotLeakATopLevelReplyValueThatTurnsOutToBeAScalar() {
    let result = scan(#"{"reply":true,"x":1}"#)
    #expect(result.reply == "")
    #expect(result.state == .awaitingReply)
  }

  @Test func shouldStillFindALaterCorrectlyTypedReplyAfterAnEarlierMistypedOne() {
    let result = scan(#"{"changeSet":[{"reply":123}],"reply":"hi"}"#)
    #expect(result.reply == "hi")
    #expect(result.state == .completed)
  }

  @Test func shouldAbandonATruncatedUnicodeEscapeAndRedispatchTheTerminatingQuoteAsTheStringEnd() {
    let result = scan(#"{"reply":"a\u12","after":"LEAK"}"#)
    #expect(result.reply == "a")
    #expect(result.state == .completed)
  }

  @Test func shouldAbandonATruncatedUnicodeEscapeAndRedispatchAFollowingBackslashAsANewEscape() {
    #expect(scan(#"{"reply":"a\u12\nb"}"#).reply == "a\nb")
  }

  @Test func shouldDecodeUppercaseAndMixedCaseUnicodeHexDigits() {
    #expect(scan(#"{"reply":"ééé"}"#).reply == "ééé")
  }

  @Test func shouldDecodeUnicodeEscapeZero() {
    #expect(scan(#"{"reply":"a\u0000b"}"#).reply == "a\u{0}b")
  }

  @Test func shouldHandleAnEmptyReplyString() {
    let result = scan(#"{"reply":""}"#)
    #expect(result.reply == "")
    #expect(result.replyPieces.isEmpty)
    #expect(result.state == .completed)
  }

  @Test func shouldEmitCorrectlyWhenReplyIsTheFirstKey() {
    let result = scan(#"{"reply":"first","changeSet":[]}"#)
    #expect(result.reply == "first")
    #expect(result.state == .completed)
  }

  @Test func shouldHandlePrettyPrintedJSONWithWhitespaceAndNewlinesBetweenTokens() {
    let result = scan(["{", "  \"changeSet\": [],", "  \"reply\": \"hello there\"", "}"].joined(separator: "\n"))
    #expect(result.reply == "hello there")
    #expect(result.state == .completed)
  }

  @Test func shouldHandOverEveryChangeSetElementAfterTheReplyParsedExactly() {
    let result = scan(changesAfterReply)
    #expect(result.reply == "Here are the changes.")
    expectElements(result, equal: changeElements)
  }

  @Test func shouldHandOverEveryChangeSetElementThatPrecedesTheReply() {
    let result = scan(changesBeforeReply)
    #expect(result.reply == "Changes first.")
    expectElements(result, equal: changeElements)
  }

  @Test(arguments: [changesAfterReply, changesBeforeReply])
  func shouldProduceTheSameElementsForEveryTwoChunkSplitIncludingInsideStringsEscapesAndNestedContainers(payload: String) {
    for result in scan(payload, everyTwoChunkSplit: true) { expectElements(result, equal: changeElements) }
  }

  @Test func shouldProduceTheSameElementsWhenFedOneCharacterAtATime() {
    let result = scan(changesAfterReply, sizes: Array(repeating: 1, count: utf16Count(changesAfterReply)))
    #expect(result.reply == "Here are the changes.")
    expectElements(result, equal: changeElements)
  }

  @Test func shouldReleaseAnElementAsSoonAsItsClosingBraceArrivesBeforeTheArrayCloses() {
    let units = Array(changesAfterReply.utf16)
    let firstEnd = offset(of: changeElements[0], in: changesAfterReply) + utf16Count(changeElements[0])
    var scanner = ReplyScanner()
    let early = scanner.consume(utf16: Array(units[..<(firstEnd - 1)]))
    #expect(!early.contains { if case .element = $0 { true } else { false } })
    let released = scanner.consume(utf16: [units[firstEnd - 1]])
    #expect(released.count == 1)
    guard case .element(let element)? = released.first else {
      Issue.record("expected an element event")
      return
    }
    #expect(jsonEqual(element.source, changeElements[0]))
    #expect(scanner.consume(utf16: []) == [])
  }

  @Test func shouldHandOverNothingWhenThePayloadHasNoChangeSet() {
    let result = scan(#"{"reply":"Just talking.","question":"Why?"}"#, sizes: [5])
    #expect(result.reply == "Just talking.")
    #expect(result.elements.isEmpty)
  }

  @Test func shouldHandOverNothingForAnEmptyChangeSet() {
    #expect(scan(#"{"reply":"x","changeSet":[]}"#, sizes: [3]).elements.isEmpty)
  }

  @Test func shouldSkipElementsThatDoNotParseAreNotObjectsOrLackAStringOpAndKeepTheRest() {
    let payload = #"{"reply":"x","changeSet":[{"op":"a",},"text",42,["op"],{"op":7},{"kind":"thread"},{"op":undefined},{"op":"premise.update"},null]}"#
    expectElements(scan(payload), equal: [#"{"op":"premise.update"}"#])
  }

  @Test func shouldIgnoreAChangeSetKeyThatIsNotTopLevel() {
    let payload = #"{"reply":"x","lookups":[{"tool":"t","args":{"changeSet":[{"op":"hidden"}]}}]}"#
    #expect(scan(payload).elements.isEmpty)
  }

  @Test func shouldNeverHandOverAnElementTheStreamCutOffBeforeItsClosingBrace() {
    let cut = String(changesAfterReply.prefix(upTo: changesAfterReply.range(of: #""promise.create""#)?.lowerBound ?? changesAfterReply.endIndex))
    expectElements(scan(cut), equal: Array(changeElements.prefix(2)))
  }

  @Test func shouldStreamOnlyTheFirstTopLevelReplyWhenTheKeyRepeats() {
    #expect(scan(#"{"reply":"first","changeSet":[{"op":"a"}],"reply":"second"}"#, sizes: [4]).reply == "first")
  }

  @Test func shouldSkipAnElementThatClosesAsInvalidJSONAndStillHandOverTheOnesAfterIt() {
    let payload = #"{"reply":"x","changeSet":[{"op":"lost" oops},{"op":"kept","note":"a\"}b"}]}"#
    expectElements(scan(payload, sizes: [7]), equal: [#"{"op":"kept","note":"a\"}b"}"#])
  }

  @Test func shouldIgnoreEverythingAfterTheTopLevelObjectCloses() {
    let result = scan("{\"reply\":\"x\",\"changeSet\":[{\"op\":\"a\"}]}\n{\"reply\":\"y\",\"changeSet\":[{\"op\":\"b\"}]}")
    #expect(result.reply == "x")
    expectElements(result, equal: [#"{"op":"a"}"#])
  }

  @Test func shouldHandlePrettyPrintedChangeSetElements() throws {
    let document = try #require(JSONSerialization.jsonObject(with: Data(changesAfterReply.utf8)) as? [String: Any])
    let pretty = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .withoutEscapingSlashes])
    let result = scan(String(decoding: pretty, as: UTF8.self), sizes: [11])
    expectElements(result, equal: changeElements)
  }
}
