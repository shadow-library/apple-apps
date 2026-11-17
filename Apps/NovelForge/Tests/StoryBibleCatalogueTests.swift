import Foundation
import NovelForgeCore
import ShadowCore
import Testing

@testable import NovelForge

@MainActor
@Suite("StoryBibleCatalogue")
struct StoryBibleCatalogueTests {
  private struct Spec {
    let section: BiblePageSection
    let slug: String
    let body: String?
    var title: String?
  }

  private let novel = UUID()

  private func entity(_ key: String, _ type: EntityType, _ name: String, significance: EntitySignificance = .minor, body: String? = nil) -> EntityRecord {
    EntityRecord(novel: novel, entity: key, type: .known(type), name: name, significance: .known(significance), body: body)
  }

  private func summaries(_ specs: [Spec]) async throws -> [PageSummary] {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await LibraryService(store: store).create(title: "Ashfall", notes: "")
    try await store.writeDomain { transaction throws(DomainError) in
      for spec in specs {
        let frontmatter: [String: JSONValue]? = spec.title.map { ["title": .string($0)] }
        try Pages.create(novel: novel, section: spec.section, slug: spec.slug, frontmatter: frontmatter, body: spec.body, in: &transaction)
      }
    }
    return try #require(try await store.load(StoryBibleContents.self, novel).pages.value).items
  }

  @Test("should group records by topic with major entries first and pages after records")
  func groupsByTopic() async throws {
    let catalogue = BibleCatalogue(
      pages: try await summaries([Spec(section: .world, slug: "the-city", body: "Walls.", title: "The City")]),
      entities: [entity("b", .character, "Bryn"), entity("a", .character, "Aldo", significance: .major), entity("k", .faction, "The Guild")])

    let groups = catalogue.groups(kind: .all, query: "")

    #expect(groups.map(\.topic) == [.people, .factions, .places])
    #expect(groups[0].entries.map(\.name) == ["Aldo", "Bryn"])
  }

  @Test("should file a concept by its name and a planner page under story core")
  func conceptAndSectionTopics() async throws {
    let catalogue = BibleCatalogue(
      pages: try await summaries([Spec(section: .project, slug: "timeline", body: "Events.", title: "Timeline")]),
      entities: [entity("c", .concept, "The Old Magic"), entity("d", .concept, "Fate")])

    let topics = Dictionary(uniqueKeysWithValues: catalogue.entries.map { ($0.name, $0.topic) })

    #expect(topics["The Old Magic"] == .power)
    #expect(topics["Fate"] == .lore)
    #expect(topics["Timeline"] == .core)
  }

  @Test("should file an author-only page under author-only")
  func authorOnly() async throws {
    let catalogue = BibleCatalogue(pages: try await summaries([Spec(section: .ai, slug: "author-notes", body: "Private.", title: "Author notes")]), entities: [])

    #expect(catalogue.entries.first?.topic == .author)
  }

  @Test("should split empty placeholder pages out of the entries")
  func emptyPagesAreSeparate() async throws {
    let catalogue = BibleCatalogue(pages: try await summaries([Spec(section: .plot, slug: "arc", body: "  "), Spec(section: .plot, slug: "act-one", body: "Text.")]), entities: [])

    #expect(catalogue.entries.count == 1)
    #expect(catalogue.emptyPages.map(\.slug) == ["arc"])
    #expect(catalogue.matchingEmptyPages(kind: .records, query: "").isEmpty)
  }

  @Test("should filter by kind and search case- and diacritic-insensitively")
  func filtersAndSearch() async throws {
    let catalogue = BibleCatalogue(
      pages: try await summaries([Spec(section: .world, slug: "cafe", body: "A café.", title: "Café Guide")]), entities: [entity("e", .character, "Élan", body: "A dancer.")])

    #expect(catalogue.groups(kind: .records, query: "").flatMap(\.entries).map(\.name) == ["Élan"])
    #expect(catalogue.groups(kind: .guides, query: "").flatMap(\.entries).map(\.name) == ["Café Guide"])
    #expect(catalogue.groups(kind: .all, query: "  ELAN ").flatMap(\.entries).map(\.name) == ["Élan"])
    #expect(catalogue.groups(kind: .all, query: "dancer").flatMap(\.entries).count == 1)
    #expect(catalogue.groups(kind: .all, query: "zzz").isEmpty)
  }

  @Test("should route entries to their page or entity")
  func routes() async throws {
    let catalogue = BibleCatalogue(pages: try await summaries([Spec(section: .world, slug: "city", body: "Text.")]), entities: [entity("mara", .character, "Mara")])

    #expect(Set(catalogue.entries.map(\.route)) == [.page(PageAddress(section: .world, slug: "city")), .entity("mara")])
  }

  @Test("should derive a key from a name across scripts and drop symbols")
  func slugs() {
    #expect(BibleKey.slug(from: "  The  City of Ash! ") == "the-city-of-ash")
    #expect(BibleKey.slug(from: "Élan") == "élan")
    #expect(BibleKey.slug(from: "!!!") == "")
  }

  @Test("should group inside a topic by record type with the reference headers and put pages under guides")
  func subgroups() async throws {
    let catalogue = BibleCatalogue(
      pages: try await summaries([Spec(section: .world, slug: "the-guild-hall", body: "Text.", title: "Guild notes")]),
      entities: [entity("c", .concept, "The Cast of Ash"), entity("f", .faction, "The Guild"), entity("g", .concept, "Guild Law")])

    let factions = try #require(catalogue.groups(kind: .all, query: "").first { $0.topic == .factions })
    let people = try #require(catalogue.groups(kind: .all, query: "").first { $0.topic == .people })

    #expect(factions.subgroups.map(\.key) == [.type(.faction), .groups, .guides])
    #expect(people.subgroups.map(\.key) == [.groups])
  }
}
