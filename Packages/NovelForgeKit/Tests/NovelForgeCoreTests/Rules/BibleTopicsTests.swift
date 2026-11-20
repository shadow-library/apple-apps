import Foundation
import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

struct BibleTopicsTests {
  private let novel = UUID()

  private func page(_ section: BiblePageSection, _ slug: String, title: String? = nil, body: String = "Text.") throws -> PageSummary {
    let frontmatter: [String: JSONValue]? = title.map { ["title": .string($0)] }
    return try #require(Pages.summaries(of: [PageRecord(novel: novel, section: section, slug: slug, content: PageContent(frontmatter: frontmatter, body: body))]).first)
  }

  private func entity(_ type: EntityType, _ name: String, body: String? = nil) -> EntityRecord {
    EntityRecord(novel: novel, entity: "key", type: .known(type), name: name, body: body)
  }

  @Test func shouldMatchTheAuthorOnlyPatternWhereJavaScriptWordBoundariesAreAsciiOnly() {
    #expect(BibleTopics.isAuthorOnly("éauthor only"))
    #expect(BibleTopics.isAuthorOnly("Author-Notes"))
    #expect(BibleTopics.isAuthorOnly("authoronly"))
    #expect(BibleTopics.isAuthorOnly("For the   Author"))
  }

  @Test func shouldNotMatchTheAuthorOnlyPatternAcrossWordCharactersOrDots() {
    #expect(!BibleTopics.isAuthorOnly("author only_x"))
    #expect(!BibleTopics.isAuthorOnly("author.only"))
    #expect(!BibleTopics.isAuthorOnly("co_author_only"))
    #expect(!BibleTopics.isAuthorOnly("authors only"))
  }

  @Test func shouldSplitKeywordsAtCombiningMarksLikeThePropertyClassesDo() {
    #expect(BibleTopics.topic(of: entity(.concept, "cast\u{301}")) == .people)
    #expect(BibleTopics.topic(of: entity(.concept, "Fate")) == .lore)
  }

  @Test func shouldFileEntitiesByTypeAndConceptsByNameThenExcerpt() {
    #expect(BibleTopics.topic(of: entity(.item, "Spoon")) == .objects)
    #expect(BibleTopics.topic(of: entity(.concept, "The Old Magic")) == .power)
    #expect(BibleTopics.topic(of: entity(.concept, "Dream", body: "# Dream\n\nA tower in the sky.")) == .places)
  }

  @Test func shouldFilePagesByAuthorMarkerPowerSectionKeywordThenSection() throws {
    #expect(BibleTopics.topic(of: try page(.ai, "notes", title: "For the author")) == .author)
    #expect(BibleTopics.topic(of: try page(.power, "city-rules")) == .power)
    #expect(BibleTopics.topic(of: try page(.world, "the-city")) == .places)
    #expect(BibleTopics.topic(of: try page(.project, "the-war", title: "The war")) == .core)
    #expect(BibleTopics.topic(of: try page(.project, "cast-notes", title: "Cast")) == .people)
    #expect(BibleTopics.topic(of: try page(.lore, "dusk", title: "Dusk")) == .lore)
  }

  @Test func shouldTakeTheExcerptFromTheFirstParagraphAfterTheRepeatedHeading() {
    let record = entity(
      .character, "Mara", body: "# **Mara**\n\n- She carries [letters](https://example.com) across the ash plains and trusts no one at all, least of all the guild.\n\nSecond.")

    #expect(BibleTopics.excerpt(of: record, limit: 60) == "She carries letters across the ash plains and trusts no one…")
    #expect(BibleTopics.excerpt(of: entity(.character, "Mara", body: "   ")) == "")
  }

  @Test func shouldKeepAHeadingThatIsNotTheEntityName() {
    #expect(BibleTopics.excerpt(of: entity(.character, "Mara", body: "# Early life\n\nBorn in ash.")) == "Born in ash.")
  }
}
