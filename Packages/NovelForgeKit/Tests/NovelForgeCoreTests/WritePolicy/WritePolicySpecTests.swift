import Foundation
import Testing

@testable import NovelForgeCore

struct WritePolicySpecTests {
  private struct Catalog: Decodable {
    let regexes: [Entry]
  }

  private struct Entry: Decodable {
    let location: String
    let source: String?
    let flags: String?
  }

  private static let quote = "Mara keeps the lantern burning"
  private static let said = "The tower falls at dawn and Mara keeps the lantern burning."

  private func op(_ json: String) throws -> ChangeOp {
    let ops = try parseChangeSet(try OrderedJSON(parsing: "[\(json)]"), options: ChangeSetValidationOptions(entityMaterialization: false))
    return try #require(ops.first)
  }

  @Test func shouldPortEveryReferenceRegexVerbatim() throws {
    let rule = try #require(QuoteRule.shared)
    let catalog = try ReferenceFixture.decode(Catalog.self, from: "text/reference-regexes.json")
    let expected = catalog.regexes.filter { $0.location.hasPrefix("apps/novel-forge-server/src/modules/refinement/write-policy.ts:") }
    let ported = [
      rule.hedgeCue, rule.negationCue, rule.rejectionCue, rule.clauseBreak, rule.trailingClosers, rule.sentenceBreak, rule.spacelessScript, rule.singleQuotes, rule.doubleQuotes,
      rule.dashes, rule.whitespaceRun, rule.quoteMarks, rule.word, rule.possessive,
    ]
    #expect(ported.count == expected.count)
    for (regex, entry) in zip(ported, expected) {
      #expect(regex.source == entry.source, "\(entry.location)")
      #expect(regex.flags == entry.flags, "\(entry.location)")
    }
  }

  @Test func shouldKeepHalfASurrogatePairInASpacelessBigram() throws {
    let rule = try #require(QuoteRule.shared)
    #expect(rule.contentTokens("中𠀀") == [[0x4E2D, 0xD840], [0xD840, 0xDC00]])
    #expect(rule.contentTokens("中") == [[0x4E2D]])
    #expect(rule.contentTokens("𠀀") == [[0xD840, 0xDC00]])
    #expect(!Set(rule.contentTokens("中𠀀")).contains([0x4E2D]))
  }

  @Test func shouldCountWordLengthsInCodeUnits() throws {
    let rule = try #require(QuoteRule.shared)
    #expect(rule.contentTokens("𐐀 x") == ["𐐨".jsCodeUnits])
    #expect(rule.contentTokens("stories glass boss bells mara's") == ["story", "glass", "boss", "bell", "mara"].map(\.jsCodeUnits))
  }

  @Test func shouldTreatAnEmptyNeedleAsFoundOnlyInANonEmptySentence() throws {
    let rule = try #require(QuoteRule.shared)
    #expect(!rule.quoteIsTentative("", ""))
    #expect(!rule.quoteIsTentative("\"  \"", "   "))
    #expect(rule.quoteIsTentative("", "Maybe."))
    #expect(!rule.quoteFoundIn("", "Maybe."))
  }

  @Test func shouldBuildTheSharedPolicy() {
    #expect(QuoteRule.shared != nil)
    #expect(WritePolicy.shared != nil)
  }

  @Test func shouldCardEveryOpWhenThePolicyCouldNotBeBuilt() throws {
    let entity = try op(#"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"keeps the lantern burning","quote":"\#(Self.quote)"}"#)
    let milestone = try op(#"{"op":"milestone.upsert","milestoneKey":"m1","label":"tower falls at dawn"}"#)
    let input = WritePolicyInput(ops: [entity, milestone], authorMessage: Self.said, mode: .auto, ideas: .apply, hold: .none, state: WritePolicyState())
    #expect(WritePolicy.split(input).direct == [entity, milestone])
    let failed = WritePolicy.split(input, with: nil)
    #expect(failed.dispositions == [.card(index: 0, reason: .heldForReview, rule: nil), .card(index: 1, reason: .heldForReview, rule: nil)])
    #expect(failed.direct.isEmpty && failed.sources.isEmpty && failed.cards == [entity, milestone] && failed.ops == [entity, milestone])
    #expect(failed.held == .turn)
    var empty = input
    empty.ops = []
    #expect(WritePolicy.split(empty, with: nil).held == .none)
  }

  @Test func shouldApplyAStatedQuoteAndCardItWhenAnOverrideHolds() throws {
    let policy = try #require(WritePolicy.shared)
    let entity = try op(#"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"keeps the lantern burning","quote":"\#(Self.quote)"}"#)
    let input = WritePolicyInput(ops: [entity], authorMessage: Self.said, mode: .auto, hold: .none, state: WritePolicyState())
    #expect(policy.splitChangeSet(input).dispositions == [.direct(index: 0, source: .quoted)])
    var discussing = input
    discussing.justDiscussing = true
    discussing.hold = .turn
    let split = policy.splitChangeSet(discussing)
    #expect(split.dispositions == [.card(index: 0, reason: .justDiscussing, rule: nil)])
    #expect(split.held == .none)
    #expect(split.direct.isEmpty && split.cards == [entity])
  }

  @Test func shouldReportTheHoldOnlyWhenItTurnedAnOpThatWouldHaveApplied() throws {
    let policy = try #require(WritePolicy.shared)
    let entity = try op(#"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"keeps the lantern burning","quote":"\#(Self.quote)"}"#)
    let milestone = try op(#"{"op":"milestone.upsert","milestoneKey":"m1","label":"tower falls at dawn"}"#)
    let input = WritePolicyInput(ops: [milestone, entity], authorMessage: Self.said, mode: .auto, ideas: .apply, hold: .writerRead, state: WritePolicyState())
    let held = policy.splitChangeSet(input)
    #expect(held.dispositions == [.direct(index: 0, source: .idea), .card(index: 1, reason: .heldForReview, rule: nil)])
    #expect(held.held == .writerRead)
    let removal = try op(#"{"op":"entity.remove","entityKey":"mara"}"#)
    let untouched = policy.splitChangeSet(WritePolicyInput(ops: [removal], authorMessage: Self.said, mode: .auto, hold: .turn, state: WritePolicyState()))
    #expect(untouched.held == .none)
  }

  @Test func shouldMoveAnOpThatNamesACardRecordTransitively() throws {
    let policy = try #require(WritePolicy.shared)
    let ops = [
      try op(#"{"op":"entity.remove","entityKey":"vell"}"#),
      try op(#"{"op":"milestone.upsert","milestoneKey":"m1","label":"tower falls"}"#),
      try op(#"{"op":"milestone.upsert","milestoneKey":"m1","label":"tower falls at dawn","subjectEntityKey":"vell"}"#),
    ]
    let split = policy.splitChangeSet(WritePolicyInput(ops: ops, authorMessage: Self.said, mode: .auto, ideas: .apply, hold: .none, state: WritePolicyState()))
    #expect(
      split.dispositions == [
        .card(index: 0, reason: .alwaysCard, rule: .removal), .card(index: 1, reason: .notAllowlisted, rule: nil), .card(index: 2, reason: .notAllowlisted, rule: nil),
      ]
    )
    #expect(split.sources.isEmpty)
  }

  @Test func shouldKeepTheLastFieldsOfARefListedTwice() {
    let state = WritePolicyState(current: [
      (ref: "entity:mara", fields: OrderedJSONObject([(key: "body", value: .string("first"))])),
      (ref: "entity:mara", fields: OrderedJSONObject([(key: "body", value: .string("last"))])),
    ])
    #expect(state.fields(of: "entity:mara")?["body"] == .string("last"))
    #expect(state.fields(of: "entity:e\u{301}") == nil)
    #expect(!state.has("entity:\u{e9}") && state.has("entity:mara"))
  }
}
