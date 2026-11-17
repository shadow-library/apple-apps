import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

struct BibleRolesTests {
  private let novel = UUID()

  private func page(_ section: BiblePageSection, _ slug: String, _ title: String, body: String = "Text.") throws -> PageSummary {
    let content = PageContent(frontmatter: ["title": .string(title)], body: body)
    return try #require(Pages.summaries(of: [PageRecord(novel: novel, section: section, slug: slug, content: content)]).first)
  }

  // platform/apps/novel-forge-web/src/lib/bible-topics.ts:249 lists the stages in the manifest's order (bible-manifest.ts:27)
  @Test func shouldFileADocumentCoveringSeveralRolesUnderTheEarliestStage() throws {
    let pages = [
      try page(.world, "the-guilds", "The Guilds"), try page(.lore, "history-of-cities", "History"), try page(.project, "premise", "Premise", body: "  "),
      try page(.ai, "people", "Roster"),
    ]
    let faction = EntityRecord(novel: novel, entity: "a", type: .known(.faction), name: "A")
    let stages = BibleRoles.stages(pages: pages, entities: [faction], volumes: [])
    #expect(pages.map { stages.stage(of: $0) } == [.factionsAndLocations, .world, nil, .characters])
    #expect(BibleStage.allCases == bibleStageOrder)
  }
}

// apps/novel-forge-server/src/modules/bible/document/bible-document.service.ts:40
struct PageExcerptTests {
  private let novel = UUID()

  @Test func shouldListAnExcerptOnlyForAPageWithText() throws {
    let records = [
      PageRecord(novel: novel, section: .world, slug: "tides", content: PageContent(body: "Salt water rises.")),
      PageRecord(novel: novel, section: .world, slug: "blank", content: PageContent(body: " \n ")),
      PageRecord(novel: novel, section: .world, slug: "heading", content: PageContent(body: "# Only a heading")),
    ]
    let summaries = Pages.summaries(of: records)
    #expect(summaries.map(\.slug) == ["blank", "heading", "tides"])
    #expect(summaries.map(\.excerpt) == [nil, nil, "Salt water rises."])
  }
}
