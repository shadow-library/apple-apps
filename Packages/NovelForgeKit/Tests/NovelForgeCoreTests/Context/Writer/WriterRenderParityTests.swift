import ShadowText
import Testing

@testable import NovelForgeCore

struct WriterRenderParityTests {
  private static let fixture = WriterRenderFixture.shared

  private func withheld(_ policy: WriterDisclosurePolicy) -> [WriterRenderFixture.Withheld] {
    policy.withheld.map(WriterRenderFixture.Withheld.init).sorted { $0.field.unicodeScalars.lexicographicallyPrecedes($1.field.unicodeScalars) }
  }

  private func expectRendered(_ actual: WriterRendered, _ policy: WriterDisclosurePolicy, _ expected: WriterRenderFixture.Rendered, _ id: String) {
    #expect(actual.sections == expected.sections, "\(id) sections")
    #expect(actual.reservations.map(WriterRenderFixture.Reservation.init) == expected.reservations, "\(id) reservations")
    #expect(actual.omitted.map(WriterRenderFixture.Omission.init) == expected.omitted, "\(id) omitted")
    #expect(withheld(policy) == expected.withheld, "\(id) withheld")
  }

  @Test func shouldKeepTheReferenceCapsAndPriorities() throws {
    let fixture = try Self.fixture.get()
    let caps: [String: Int] = [
      "chapterPlan": WriterRender.Cap.chapterPlan, "prevEnding": WriterRender.Cap.prevEnding, "continuationState": WriterRender.Cap.continuationState,
      "recentSummaries": WriterRender.Cap.recentSummaries, "povCard": WriterRender.Cap.povCard, "castCard": WriterRender.Cap.castCard, "knownFacts": WriterRender.Cap.knownFacts,
      "chapterReveals": WriterRender.Cap.chapterReveals, "readerKnows": WriterRender.Cap.readerKnows, "hiddenConstraints": WriterRender.Cap.hiddenConstraints,
      "allowedClues": WriterRender.Cap.allowedClues, "openCanon": WriterRender.Cap.openCanon, "volumeGoal": WriterRender.Cap.volumeGoal,
      "completedVolumes": WriterRender.Cap.completedVolumes, "writingStyle": WriterRender.Cap.writingStyle, "writerLines": WriterRender.Cap.writerLines,
      "pluginSection": WriterRender.Cap.pluginSection,
    ]
    let priorities: [String: Int] = [
      "citedPage": WriterRender.Priority.citedPage, "castState": WriterRender.Priority.castState, "castCard": WriterRender.Priority.castCard,
      "excessCard": WriterRender.Priority.excessCard, "readerKnows": WriterRender.Priority.readerKnows, "pluginSection": WriterRender.Priority.pluginSection,
    ]
    #expect(caps == fixture.caps)
    #expect(priorities == fixture.priorities)
  }

  @Test func shouldRenderEveryCompletedVolumesCaseAsTheReference() throws {
    for item in try Self.fixture.get().completedVolumes {
      var policy = try (item.policy ?? WriterRenderFixture.PolicySpec(chapter: 5, lockedFacts: [], plannerOnly: [], plannerPages: [])).policy()
      let volumes = item.volumes.map(\.volume)
      let text: String?
      if item.policy == nil {
        text = try WriterRender.renderCompletedVolumes(volumes, maxTokens: item.maxTokens)
      } else {
        text = try WriterRender.renderCompletedVolumes(volumes, maxTokens: item.maxTokens) { summary throws(DisclosureError) in try policy.scrub(summary, .summary) }
      }
      #expect(text == item.expected, "\(item.id)")
      #expect(withheld(policy) == item.withheld, "\(item.id) withheld")
    }
  }

  @Test func shouldRenderEveryPreviousEndingCaseAsTheReference() throws {
    for item in try Self.fixture.get().previousEnding {
      var policy = try item.policy.policy()
      let row = item.row.map { WriterEndingRow(finalized: $0.status == "done", isolated: $0.isolated, content: $0.content, summary: $0.summary) }
      let draft = try item.draft.map {
        WriterEndingDraft(
          body: $0.body, summary: $0.summary, state: try $0.stateJson.map { try OrderedJSON(parsing: $0) }, isolated: $0.isolated, staleReason: $0.staleReason)
      }
      let caps = item.caps.map { WriterEndingCaps(ending: $0.ending, state: $0.state) } ?? .writer
      let previous = try WriterRender.previousEnding(chapter: item.chapter, row: row, draft: draft, rawIsolated: item.rawIsolated, disclosure: &policy, caps: caps)
      #expect(previous.ending == item.expected.ending, "\(item.id) ending")
      #expect(previous.state == item.expected.state, "\(item.id) state")
      expectRendered(
        previous.reserved, policy,
        WriterRenderFixture.Rendered(sections: item.expected.sections, reservations: item.expected.reservations, omitted: [], withheld: item.expected.withheld), item.id)
    }
  }

  @Test func shouldRenderEveryKnowledgeCaseAsTheReference() throws {
    for item in try Self.fixture.get().knowledge {
      var policy = try item.policy.policy()
      var rendered = WriterRendered()
      if item.contract {
        rendered = try WriterRender.knowledgeSections(view: item.view.view, chapterCast: Set(item.chapterCast.map { JSString($0) }), disclosure: &policy)
      }
      rendered.append(try WriterRender.allowedClues(disclosure: policy))
      expectRendered(rendered, policy, item.expected, item.id)
    }
  }

  @Test func shouldRenderEveryWriterLinesCaseAsTheReference() throws {
    for item in try Self.fixture.get().writerLines {
      var policy = try item.policy.policy()
      expectRendered(try WriterRender.writerLines(item.entries.map(\.entry), disclosure: &policy), policy, item.expected, item.id)
    }
  }

  @Test func shouldRenderEveryWriterBriefCaseAsTheReference() throws {
    for item in try Self.fixture.get().brief {
      var policy = try item.policy.policy()
      let brief = try WriterRender.writerBrief(item.brief?.input, canonFacts: item.facts.map(\.fact), disclosure: &policy)
      #expect(brief.chapterBrief == item.expected.chapterBrief, "\(item.id) brief")
      #expect(brief.endingContract == item.expected.endingContract, "\(item.id) ending")
      #expect(withheld(policy) == item.expected.withheld, "\(item.id) withheld")
    }
  }

  @Test func shouldRenderEveryWritingStyleCaseAsTheReference() throws {
    for item in try Self.fixture.get().writingStyle {
      var policy = try item.policy.policy()
      #expect(try WriterRender.writingStyleSection(item.stored, disclosure: &policy) == item.expected.section, "\(item.id)")
      #expect(withheld(policy) == item.expected.withheld, "\(item.id) withheld")
    }
  }
}
