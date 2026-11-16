import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let emptyFields = ProgressFields(
  premise: nil,
  protagonistKey: nil,
  opposition: nil,
  theme: nil,
  readerPromise: nil,
  endingQuestion: nil,
  ending: nil,
  firstVolumeGoal: nil,
  nextChapterPlanned: false,
  chapterOneWritten: false
)

private let emptyProject = ProgressProjectFields(premise: nil, protagonistKey: nil, opposition: nil, theme: nil, readerPromise: nil, endingQuestion: nil, ending: nil)

private func overrideMap(_ entries: [JSONValue]) throws -> [JSString: ProgressOverride] {
  Dictionary(
    jsEntries: try entries.map { entry in
      (key: try entry.at(0).string(), value: ProgressOverride(status: try overrideKind(entry.at(1)), entryId: Int64(try entry.at(2).int())))
    })
}

private func overrideKind(_ value: JSONValue) throws -> ProgressOverrideKind {
  if let name = value.stringValue { return try ProgressOverrideKind(rawValue: name).orThrow("override kind \(name)") }
  return ProgressOverrideKind.allCases[try value.int()]
}

private func status(_ items: [ProgressItem], _ key: ProgressItemKey) -> ProgressItem? {
  items.first { $0.key == key }
}

struct ProgressParityTests {
  private static func texts() throws -> [String?] {
    try RuleFixture.section("progress", "fieldTexts").map { try $0.optionalString() }
  }

  @Test func shouldMatchTheReferenceChecklistTextsAndKeys() throws {
    let checklist = try RuleFixture.section("progress", "checklist")
    let items = computeProgress(emptyFields, overrides: [:])
    #expect(items.map(\.key.rawValue) == (try checklist.map { try $0.at(0).string() }))
    #expect(items.map(\.label) == (try checklist.map { try $0.at(1).string() }))
    #expect(items.map(\.why) == (try checklist.map { try $0.at(2).string() }))
    #expect(progressItemKeys.map(\.rawValue) == (try RuleFixture.section("progress", "itemKeys").strings()))
  }

  @Test func shouldMatchTheReferenceKeyFromTopicOnEveryTopic() throws {
    for row in try RuleFixture.section("progress", "topics") {
      #expect(progressKeyFromTopic(try row.at(0).string()) == (try row.at(1).optionalString()))
    }
  }

  @Test func shouldMatchTheReferenceOverridesOnEveryFixtureCase() throws {
    let payloads = try RuleFixture.section("progress", "payloads").map { Optional($0) }
    let kinds = try RuleFixture.section("progress", "entryKinds").strings()
    let topics = try RuleFixture.section("progress", "topicPool").strings()
    let cases = try RuleFixture.section("progress", "overrides")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let entries = try row.at(0).list().map { entry in
        ProgressOverrideEntry(id: Int64(try entry.at(0).int()), kind: kinds[try entry.at(1).int()], topic: topics[try entry.at(2).int()], payload: payloads[try entry.at(3).int()])
      }
      return progressOverridesFrom(entries) == (try overrideMap(try row.at(1).list()))
    }
    #expect(failed.isEmpty, "overrides differ for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceChecklistOnEveryFixtureCase() throws {
    let texts = try Self.texts()
    let cases = try RuleFixture.section("progress", "compute")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let picks = try row.at(0).ints().map { texts[$0] }
      let flags = try row.at(1).list().map { try $0.bool() }
      let fields = ProgressFields(
        premise: picks[0],
        protagonistKey: picks[1],
        opposition: picks[2],
        theme: picks[3],
        readerPromise: picks[4],
        endingQuestion: picks[5],
        ending: picks[6],
        firstVolumeGoal: picks[7],
        nextChapterPlanned: flags[0],
        chapterOneWritten: flags[1]
      )
      let items = computeProgress(fields, overrides: try overrideMap(try row.at(2).list()))
      let codes: [Character: ProgressStatus] = ["o": .open, "a": .answered, "u": .undecided, "d": .dismissed]
      let expectedStatuses = try row.at(3).string().compactMap { codes[$0] }
      let expectedIds = try row.at(4).list().map { id -> Int64? in
        let value = try id.int()
        return value == 0 ? nil : Int64(value)
      }
      return items.map(\.status) == expectedStatuses && items.map(\.overrideEntryId) == expectedIds
    }
    #expect(failed.isEmpty, "checklist differs for cases \(failed.prefix(10)) of \(failed.count)")
  }

  @Test func shouldMatchTheReferenceFieldsFromProjectOnEveryFixtureCase() throws {
    let texts = try Self.texts()
    let briefs: [ProgressNextChapter.Brief?] = [
      nil, .init(staleReason: nil), .init(staleReason: nil), .init(staleReason: ""), .init(staleReason: " "), .init(staleReason: "the author replanned"),
    ]
    let cases = try RuleFixture.section("progress", "from")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let picks = try row.at(0).ints().map { texts[$0] }
      let project = ProgressProjectFields(
        premise: picks[0],
        protagonistKey: picks[1],
        opposition: picks[2],
        theme: picks[3],
        readerPromise: picks[4],
        endingQuestion: picks[5],
        ending: picks[6]
      )
      let objectives = try row.at(1).ints().map { texts[$0] }
      let fields = progressFieldsFrom(project, volumeObjectives: objectives, next: ProgressNextChapter(chapter: try row.at(2).int(), brief: briefs[try row.at(3).int()]))
      let expected = try row.at(4)
      let goal = try expected.at(0).optionalString()
      let planned = try expected.at(1).bool()
      let written = try expected.at(2).bool()
      return fields.firstVolumeGoal == goal && fields.nextChapterPlanned == planned && fields.chapterOneWritten == written && fields.premise == project.premise
        && fields.ending == project.ending
    }
    #expect(failed.isEmpty, "fields differ for cases \(failed.prefix(10)) of \(failed.count)")
  }
}

struct ProgressSpecTests {
  @Test func shouldReportEveryItemOpenForABrandNewProject() {
    let items = computeProgress(emptyFields, overrides: [:])
    #expect(items.count == progressItemKeys.count)
    #expect(items.allSatisfy { $0.status == .open })
  }

  @Test func shouldCountTheEndingAnsweredFromEitherTheEndingQuestionOrThePlannedEnding() {
    var byQuestion = emptyFields
    byQuestion.endingQuestion = "Will Mira pay the tide?"
    var byEnding = emptyFields
    byEnding.ending = "Mira keeps the lamp lit."
    #expect(status(computeProgress(byQuestion, overrides: [:]), .ending)?.status == .answered)
    #expect(status(computeProgress(byEnding, overrides: [:]), .ending)?.status == .answered)
  }

  @Test func shouldTreatABlankStringTheSameAsNoAnswer() {
    var fields = emptyFields
    fields.premise = "   "
    #expect(status(computeProgress(fields, overrides: [:]), .premise)?.status == .open)
  }

  @Test func shouldTreatAByteOrderMarkAsBlankButNotAZeroWidthSpace() {
    var fields = emptyFields
    fields.premise = "\u{FEFF}"
    fields.theme = "\u{200B}"
    let items = computeProgress(fields, overrides: [:])
    #expect(status(items, .premise)?.status == .open)
    #expect(status(items, .theme)?.status == .answered)
  }

  @Test func shouldCarryAnOverridesStatusAndEntryIdOverridingAFilledField() {
    var fields = emptyFields
    fields.endingQuestion = "Will Mira pay the tide?"
    let overrides = [JSString("ending"): ProgressOverride(status: .undecided, entryId: 9)]
    let item = status(computeProgress(fields, overrides: overrides), .ending)
    #expect(item?.status == .undecided && item?.overrideEntryId == 9)
  }

  @Test func shouldKeepADismissedItemDismissedOnEveryLaterCall() {
    let overrides = [JSString("first_volume_goal"): ProgressOverride(status: .dismissed, entryId: 3)]
    for fields in [emptyFields, emptyFields] {
      let item = status(computeProgress(fields, overrides: overrides), .firstVolumeGoal)
      #expect(item?.status == .dismissed && item?.overrideEntryId == 3)
    }
  }

  @Test func shouldStopListingTheNextChapterItemOnceChapterOneIsWritten() {
    var written = emptyFields
    written.chapterOneWritten = true
    #expect(status(computeProgress(emptyFields, overrides: [:]), .nextChapterPlanned) != nil)
    #expect(status(computeProgress(written, overrides: [:]), .nextChapterPlanned) == nil)
    #expect(computeProgress(written, overrides: [:]).count == progressItemKeys.count - 1)
  }

  @Test func shouldIgnoreAnOverrideOfAnItemThatNoLongerApplies() {
    var written = emptyFields
    written.chapterOneWritten = true
    let overrides = [JSString("next_chapter_planned"): ProgressOverride(status: .dismissed, entryId: 1)]
    #expect(status(computeProgress(written, overrides: overrides), .nextChapterPlanned) == nil)
  }

  @Test func shouldCountTheNextChapterAnsweredOnlyWhenAPlanExists() {
    var fields = emptyFields
    fields.nextChapterPlanned = true
    #expect(status(computeProgress(fields, overrides: [:]), .nextChapterPlanned)?.status == .answered)
  }

  @Test func shouldReadAServerOwnedOverrideByItsTopicAndPayload() {
    let overrides = progressOverridesFrom([ProgressOverrideEntry(id: 9, kind: "system", topic: "progress.ending", payload: ["status": "undecided"])])
    #expect(overrides[JSString("ending")] == ProgressOverride(status: .undecided, entryId: 9))
  }

  @Test func shouldIgnoreAForgedEntryThatIsNotKindSystemEvenWithAWellFormedPayload() {
    let overrides = progressOverridesFrom([ProgressOverrideEntry(id: 9, kind: "direction", topic: "progress.ending", payload: ["status": "undecided"])])
    #expect(overrides.isEmpty)
  }

  @Test func shouldIgnoreAnEntryWithNoPayloadAMalformedPayloadOrATopicOutsideTheChecklist() {
    let overrides = progressOverridesFrom([
      ProgressOverrideEntry(id: 1, kind: "system", topic: "progress.ending", payload: nil),
      ProgressOverrideEntry(id: 2, kind: "system", topic: "progress.ending", payload: ["status": "maybe"]),
      ProgressOverrideEntry(id: 3, kind: "system", topic: "world.rules", payload: ["status": "dismissed"]),
      ProgressOverrideEntry(id: 4, kind: "system", topic: "progress.", payload: ["status": "dismissed"]),
    ])
    #expect(overrides.isEmpty)
  }

  @Test func shouldLetALaterEntryReplaceAnEarlierOneForTheSameKey() {
    let overrides = progressOverridesFrom([
      ProgressOverrideEntry(id: 1, kind: "system", topic: "progress.ending", payload: ["status": "undecided"]),
      ProgressOverrideEntry(id: 2, kind: "system", topic: "progress.ending", payload: ["status": "dismissed"]),
      ProgressOverrideEntry(id: 3, kind: "system", topic: "progress.ending", payload: ["status": "maybe"]),
    ])
    #expect(overrides[JSString("ending")] == ProgressOverride(status: .dismissed, entryId: 2))
  }

  @Test func shouldReadTheFirstVolumeAsGivenAndTreatANonStaleNextChapterBriefAsAPlan() {
    let fields = progressFieldsFrom(
      emptyProject, volumeObjectives: ["Reach the tide court.", "Never reached, later volume."], next: ProgressNextChapter(chapter: 1, brief: .init(staleReason: nil)))
    #expect(fields.firstVolumeGoal == "Reach the tide court.")
    #expect(fields.nextChapterPlanned)
    #expect(!fields.chapterOneWritten)
  }

  @Test func shouldNotCountAStaleBriefAsAPlanAndShouldKnowChapterOneIsAlreadyWritten() {
    let fields = progressFieldsFrom(emptyProject, volumeObjectives: [], next: ProgressNextChapter(chapter: 2, brief: .init(staleReason: "the author replanned")))
    #expect(!fields.nextChapterPlanned)
    #expect(fields.chapterOneWritten)
  }

  @Test func shouldTreatAMissingBriefAsUnplanned() {
    #expect(!progressFieldsFrom(emptyProject, volumeObjectives: [], next: ProgressNextChapter(chapter: 1, brief: nil)).nextChapterPlanned)
  }

  @Test func shouldTreatABlankButNonEmptyStaleReasonAsStale() {
    #expect(!progressFieldsFrom(emptyProject, volumeObjectives: [], next: ProgressNextChapter(chapter: 1, brief: .init(staleReason: " "))).nextChapterPlanned)
    #expect(progressFieldsFrom(emptyProject, volumeObjectives: [], next: ProgressNextChapter(chapter: 1, brief: .init(staleReason: ""))).nextChapterPlanned)
  }
}

struct ProgressPropertyTests {
  @Test func shouldNeverThrowOnArbitraryPayloadsAndOnlyAcceptTheTwoOverrideStatuses() throws {
    try forAll(iterations: 300) { generator in
      let payload: JSONValue? =
        switch generator.int(in: 0...5) {
        case 0: nil
        case 1: .string(generator.unicodeString(maxLength: 6))
        case 2: .object(["status": .string(generator.pick(from: ["undecided", "dismissed", "open", generator.unicodeString(maxLength: 4)]))])
        case 3: .array([.int(Int64(generator.int(in: -9...9)))])
        case 4: .int(Int64(generator.int(in: -9...9)))
        default: .object([generator.unicodeString(maxLength: 3): .null])
        }
      let entry = ProgressOverrideEntry(id: 1, kind: "system", topic: "progress." + generator.unicodeString(maxLength: 5), payload: payload)
      for override in progressOverridesFrom([entry]).values { #expect(ProgressOverrideKind.allCases.contains(override.status)) }
    }
  }

  @Test func shouldNeverListAnItemTwiceOrOutOfChecklistOrder() throws {
    try forAll(iterations: 200) { generator in
      var fields = emptyFields
      fields.chapterOneWritten = generator.chance(0.5)
      fields.premise = generator.chance(0.5) ? generator.unicodeString(maxLength: 3) : nil
      let keys = computeProgress(fields, overrides: [:]).map(\.key)
      #expect(keys == progressItemKeys.filter { keys.contains($0) })
    }
  }
}
