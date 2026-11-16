import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Pages")
struct PageOperationTests {
  @Test
  func shouldCreateAPageWithAFoldedTitle() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let saved = try await world.store.write { try Pages.create(novel: novel, section: .world, slug: "the-city", body: "Walls.", in: &$0) }
    let page = try #require(liveRecord(try await world.page(.world, "the-city")))
    #expect(page.content == PageContent(frontmatter: ["title": "The city"], body: "Walls."))
    #expect(saved == .created(revision: try #require(try await world.versions(.world, "the-city").first).revision))
  }

  @Test
  func shouldNormaliseTheSlugToNFC() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Pages.create(novel: novel, section: .lore, slug: "e\u{301}lan", body: "x", in: &$0) }
    #expect(liveRecord(try await world.page(.lore, "\u{e9}lan"))?.slug == "\u{e9}lan")
  }

  @Test
  func shouldRefuseCreatingAPageThatExistsOrWithoutASlugOrNovel() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Pages.create(novel: novel, section: .plot, slug: "arc", in: &$0) }
    await world.expect(.documentExists(section: "plot", slug: "arc")) { try Pages.create(novel: novel, section: .plot, slug: "arc", in: &$0) }
    await world.expect(.invalidKey(field: "slug")) { try Pages.create(novel: novel, section: .plot, slug: "", in: &$0) }
    let missing = SchemaFixture.otherNovel
    await world.expect(.novelNotFound(missing)) { try Pages.save(novel: missing, section: .plot, slug: "arc", in: &$0) }
  }

  @Test
  func shouldReviseAPageIntoANewRevisionKeepingTheOldOne() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Pages.create(novel: novel, section: .power, slug: "rank", body: "one", in: &$0) }
    let saved = try await world.store.write { try Pages.revise(novel: novel, section: .power, slug: "rank", body: "two", in: &$0) }
    let versions = try await world.versions(.power, "rank")
    #expect(saved == .revised(revision: versions[0].revision))
    #expect(versions.map(\.body) == ["two", "one"])
    #expect(versions.map(\.isHead) == [true, false])
    #expect(versions[0].parent == versions[1].revision)
  }

  @Test
  func shouldWriteNothingWhenTheContentOrOnlyTheMissingTitleIsUnchanged() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Pages.create(novel: novel, section: .ai, slug: "style", body: "one", in: &$0) }
    let before = try await world.pendingChangeCount()
    let again = try await world.store.write { try Pages.save(novel: novel, section: .ai, slug: "style", frontmatter: ["title": "Style"], body: "one", in: &$0) }
    let rawAgain = try await world.store.write { try Pages.save(novel: novel, section: .ai, slug: "style", body: "one", in: &$0) }
    #expect(again == .unchanged)
    #expect(rawAgain == .unchanged)
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldSaveCreateOrReviseAndRecreateARemovedPage() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let first = try await world.store.write { try Pages.save(novel: novel, section: .project, slug: "premise", body: "a", in: &$0) }
    let second = try await world.store.write { try Pages.save(novel: novel, section: .project, slug: "premise", body: "b", in: &$0) }
    #expect(first.isCreated)
    #expect(!second.isCreated)
    try await world.run { try Pages.remove(novel: novel, section: .project, slug: "premise", in: &$0) }
    let third = try await world.store.write { try Pages.save(novel: novel, section: .project, slug: "premise", body: "c", in: &$0) }
    #expect(third.isCreated)
    #expect(liveRecord(try await world.page(.project, "premise"))?.content.body == "c")
    #expect(try await world.versions(.project, "premise").map(\.body) == ["c", "b", "a"])
  }

  @Test
  func shouldRefuseRevisingAMissingOrRemovedPage() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    await world.expect(.documentNotFound(section: "world", slug: "ghost")) { try Pages.revise(novel: novel, section: .world, slug: "ghost", body: "x", in: &$0) }
    try await world.run {
      try Pages.create(novel: novel, section: .world, slug: "ghost", in: &$0)
      try Pages.remove(novel: novel, section: .world, slug: "ghost", in: &$0)
    }
    await world.expect(.documentNotFound(section: "world", slug: "ghost")) { try Pages.revise(novel: novel, section: .world, slug: "ghost", body: "x", in: &$0) }
  }

  @Test
  func shouldPreserveMembersOfNewerVersionsWhenRevising() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let key = PageRecord.ref(novel: novel, section: .world, slug: "newer")
    try await SchemaFixture.set(key, ["natural_key": NovelForgeKey.pageKey(novel: novel, section: .world, slug: "newer").stored, "removed": false], in: world.store)
    _ = try await SchemaFixture.revise(key, ["body": "old", "frontmatter": nil, "tier": 3], in: world.store)
    try await world.run { try Pages.revise(novel: novel, section: .world, slug: "newer", body: "new", in: &$0) }
    let head = try #require(try await world.versions(.world, "newer").first)
    #expect(head.content?.json == ["body": "new", "frontmatter": ["title": "Newer"], "tier": 3])
  }

  @Test
  func shouldRestoreAnOlderVersionAsANewRevision() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Pages.create(novel: novel, section: .lore, slug: "myth", frontmatter: ["title": "Myth"], body: "one", in: &$0)
      try Pages.revise(novel: novel, section: .lore, slug: "myth", frontmatter: ["title": "Myth"], body: "two", in: &$0)
    }
    let old = try #require(try await world.versions(.lore, "myth").last)
    let saved = try await world.store.write { try Pages.restoreVersion(novel: novel, section: .lore, slug: "myth", revision: old.revision, in: &$0) }
    let versions = try await world.versions(.lore, "myth")
    #expect(saved == .revised(revision: versions[0].revision))
    #expect(versions.map(\.body) == ["one", "two", "one"])
    #expect(versions[0].revision != old.revision)
    #expect(liveRecord(try await world.page(.lore, "myth"))?.content.body == "one")
  }

  @Test
  func shouldWriteNothingWhenRestoringTheHeadAndRefuseUnknownVersions() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run { try Pages.create(novel: novel, section: .lore, slug: "myth", body: "one", in: &$0) }
    let head = try #require(try await world.versions(.lore, "myth").first)
    let before = try await world.pendingChangeCount()
    let saved = try await world.store.write { try Pages.restoreVersion(novel: novel, section: .lore, slug: "myth", revision: head.revision, in: &$0) }
    #expect(saved == .unchanged)
    #expect(try await world.pendingChangeCount() == before)
    await world.expect(.revisionNotFound("nope")) { try Pages.restoreVersion(novel: novel, section: .lore, slug: "myth", revision: "nope", in: &$0) }
    await world.expect(.documentNotFound(section: "lore", slug: "ghost")) { try Pages.restoreVersion(novel: novel, section: .lore, slug: "ghost", revision: "x", in: &$0) }
  }

  @Test
  func shouldRefuseRestoringAVersionWhoseBodyCannotBeRead() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let ref = PageRecord.ref(novel: novel, section: .world, slug: "odd")
    try await SchemaFixture.set(ref, ["natural_key": NovelForgeKey.pageKey(novel: novel, section: .world, slug: "odd").stored, "removed": false], in: world.store)
    let broken = try await SchemaFixture.revise(ref, ["body": 5], in: world.store)
    _ = try await SchemaFixture.revise(ref, ["body": "fine", "frontmatter": nil], in: world.store)
    await world.expect(.revisionUnreadable(broken)) { try Pages.restoreVersion(novel: novel, section: .world, slug: "odd", revision: broken, in: &$0) }
  }

  @Test
  func shouldKeepVersionsOfARemovedPageAndRestoreItWithItsHead() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Pages.create(novel: novel, section: .world, slug: "gone", body: "one", in: &$0)
      try Pages.revise(novel: novel, section: .world, slug: "gone", body: "two", in: &$0)
      try Pages.remove(novel: novel, section: .world, slug: "gone", in: &$0)
    }
    #expect(removedRecord(try await world.page(.world, "gone")))
    #expect(try await world.versions(.world, "gone").map(\.body) == ["two", "one"])
    await world.expect(.documentNotFound(section: "world", slug: "gone")) { try Pages.remove(novel: novel, section: .world, slug: "gone", in: &$0) }
    try await world.run { try Pages.restore(novel: novel, section: .world, slug: "gone", in: &$0) }
    #expect(liveRecord(try await world.page(.world, "gone"))?.content.body == "two")
    await world.expect(.documentNotFound(section: "world", slug: "none")) { try Pages.restore(novel: novel, section: .world, slug: "none", in: &$0) }
  }

  @Test
  func shouldReportAbsentVersionsAsNotFound() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    await world.expect(.documentNotFound(section: "world", slug: "none")) { _ = try Pages.versions(novel: novel, section: .world, slug: "none", in: $0) }
  }

  @Test
  func shouldListPagesBySectionOrderThenSlugWithTitlesAndAccess() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Pages.create(novel: novel, section: .lore, slug: "z", body: "", in: &$0)
      try Pages.create(novel: novel, section: .project, slug: "timeline", body: "# Order\none two three", in: &$0)
      try Pages.create(novel: novel, section: .project, slug: "premise", body: "Hook line", in: &$0)
      try Pages.create(novel: novel, section: .storyState, slug: "volumes", body: "v", in: &$0)
      try Pages.create(novel: novel, section: .world, slug: "gone", body: "g", in: &$0)
      try Pages.remove(novel: novel, section: .world, slug: "gone", in: &$0)
    }
    let all = try await world.store.read { try Pages.list(novel: novel, in: $0) }
    #expect(all.map { "\($0.section.rawValue)/\($0.slug)" } == ["project/premise", "project/timeline", "story_state/volumes", "lore/z"])
    #expect(all.map(\.title) == ["Premise", "Order", "Volumes", "Z"])
    #expect(all.map(\.wordCount) == [2, 5, 1, 0])
    #expect(all.map(\.isEmpty) == [false, false, false, true])
    #expect(all.map(\.plannerOnly) == [false, true, false, false])
    #expect(all.map(\.writerExcluded) == [false, true, true, false])
    let project = try await world.store.read { try Pages.list(novel: novel, section: .project, in: $0) }
    #expect(project.map(\.slug) == ["premise", "timeline"])
    #expect(try await world.store.read { try Pages.list(novel: SchemaFixture.otherNovel, in: $0) }.isEmpty)
  }

  @Test
  func shouldWriteNothingWhenResavingAnUntitledStoredPageWithIdenticalContent() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let ref = PageRecord.ref(novel: novel, section: .world, slug: "plain")
    try await SchemaFixture.set(ref, ["natural_key": NovelForgeKey.pageKey(novel: novel, section: .world, slug: "plain").stored, "removed": false], in: world.store)
    _ = try await SchemaFixture.revise(ref, ["body": "same", "frontmatter": nil], in: world.store)
    let before = try await world.pendingChangeCount()
    let saved = try await world.store.write { try Pages.save(novel: novel, section: .world, slug: "plain", body: "same", in: &$0) }
    #expect(saved == .unchanged)
    #expect(try await world.pendingChangeCount() == before)
  }

  @Test
  func shouldOrderSlugsByUTF16CodeUnitsAcrossBMPAndAstralCharacters() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    try await world.run {
      try Pages.create(novel: novel, section: .world, slug: "\u{FF5E}", in: &$0)
      try Pages.create(novel: novel, section: .world, slug: "\u{1F600}", in: &$0)
      try Pages.create(novel: novel, section: .world, slug: "a", in: &$0)
    }
    #expect(try await world.store.read { try Pages.list(novel: novel, in: $0) }.map(\.slug) == ["a", "\u{1F600}", "\u{FF5E}"])
  }

  @Test
  func shouldSkipAPageOfAnUnknownSectionWhenListing() async throws {
    let world = try await BibleWorld.make()
    let novel = world.novel
    let key = try NovelForgeKey(novel: novel, .page(section: .unknown("bestiary"), slug: "wolves"))
    try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "removed": false], in: world.store)
    _ = try await SchemaFixture.revise(key.ref, ["body": "Grey", "frontmatter": nil], in: world.store)
    try await world.run { try Pages.create(novel: novel, section: .world, slug: "known", body: "k", in: &$0) }
    #expect(try await world.store.read { try Pages.list(novel: novel, in: $0) }.map(\.slug) == ["known"])
  }

  @Test
  func shouldGiveTheRequiredEntityTypesOfAManifestSlug() {
    #expect(Pages.requiredEntityTypes(section: .world, slug: "factions-and-locations") == [.faction, .location])
    #expect(Pages.requiredEntityTypes(section: .project, slug: "premise") == [])
    #expect(Pages.requiredEntityTypes(section: .power, slug: "system-and-limits") == [.powerRule, .concept])
  }
}

extension PageVersion {
  fileprivate var body: String? { content?.body }
}

extension PageSaved {
  fileprivate var isCreated: Bool {
    guard case .created = self else { return false }
    return true
  }
}
