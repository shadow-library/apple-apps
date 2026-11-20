import Foundation
import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

private func entityTypes(_ value: JSONValue) throws -> [EntityType] {
  try value.list().map { try EntityType(rawValue: try $0.string()).orThrow("entity type") }
}

struct BibleManifestParityTests {
  @Test func shouldMatchTheReferenceManifestFieldForField() throws {
    let chapters = try RuleFixture.section("manifest", "chapters")
    #expect(chapters.count == bibleManifest.count)
    for (chapter, expected) in zip(bibleManifest, chapters) {
      let role = try expected["role"].orThrow("role")
      #expect(chapter.stage.rawValue == (try expected["stage"].orThrow("stage").string()))
      #expect(chapter.section.rawValue == (try expected["section"].orThrow("section").string()))
      #expect(chapter.slug == (try expected["slug"].orThrow("slug").string()))
      #expect(chapter.purpose == (try expected["purpose"].orThrow("purpose").string()))
      #expect(chapter.materializes == (try entityTypes(try expected["materializes"].orThrow("materializes"))))
      #expect(chapter.topics == (try expected["topics"].orThrow("topics").list().strings()))
      #expect(chapter.role.label == (try role["label"].orThrow("label").string()))
      #expect(chapter.role.sections.map(\.rawValue) == (try role["sections"].orThrow("sections").list().strings()))
      #expect(chapter.role.keywords == (try role["keywords"].orThrow("keywords").list().strings()))
    }
  }

  @Test func shouldMatchTheReferenceStageOrderAndLegacySlugs() throws {
    #expect(bibleStageOrder.map(\.rawValue) == (try RuleFixture.section("manifest", "stageOrder").strings()))
    let legacy = try RuleFixture.section("manifest", "legacy")
    #expect(legacyChapterSlugs.count == legacy.count)
    for (slug, expected) in zip(legacyChapterSlugs, legacy) {
      #expect(slug.section.rawValue == (try expected["section"].orThrow("section").string()))
      #expect(slug.slug == (try expected["slug"].orThrow("slug").string()))
      #expect(slug.stage.rawValue == (try expected["stage"].orThrow("stage").string()))
    }
  }

  @Test func shouldRenderTheManifestWordForWordAsTheReference() throws {
    let rendered = try RuleFixture.load("manifest")["rendered"].orThrow("rendered").string()
    #expect(renderManifest() == rendered)
  }

  @Test func shouldMatchTheReferenceEntityTypesOfEverySection() throws {
    let cases = try RuleFixture.section("manifest", "sectionTypes")
    #expect(cases.count >= 15)
    for row in cases {
      let section = try row["section"].orThrow("section").string()
      #expect(entityTypesForSection(section) == (try entityTypes(try row["types"].orThrow("types"))), "\(section)")
      #expect(isEntityBearingSection(section) == (try row["bearing"].orThrow("bearing").bool()), "\(section)")
    }
  }

  @Test func shouldMatchTheReferenceChapterLookupAndRequiredTypesOnEveryFixtureCase() throws {
    let cases = try RuleFixture.section("manifest", "cases")
    #expect(cases.count >= 300)
    let failed = try mismatches(cases) { row in
      let section = try row.at(0).string()
      let slug = try row.at(1).string()
      let stage = try row.at(2).optionalString()
      let required = try entityTypes(try row.at(3))
      return chapterAt(section: section, slug: slug)?.stage.rawValue == stage && requiredEntityTypesForSlug(section: section, slug: slug) == required
    }
    #expect(failed.isEmpty, "lookup differs for cases \(failed.prefix(10)) of \(failed.count)")
  }
}

struct BibleManifestSpecTests {
  @Test func shouldDeclareExactlyOneChapterPerBuilderStage() {
    #expect(bibleManifest.count == bibleStageOrder.count)
    for stage in bibleStageOrder { #expect(chapterForStage(stage).stage == stage) }
    #expect(bibleManifest.map(\.stage) == bibleStageOrder)
  }

  @Test func shouldGiveEveryChapterAUniqueSectionSlugAddress() {
    let addresses = bibleManifest.map { "\($0.section.rawValue)/\($0.slug)" }
    #expect(Set(addresses).count == addresses.count)
  }

  @Test func shouldGiveEveryChapterAtLeastOneTopic() {
    for chapter in bibleManifest { #expect(!chapter.topics.isEmpty) }
  }

  @Test func shouldNeverAskTheEscalationMapForAnEndgameTheAuthorHasNotGiven() {
    let plot = chapterForStage(.plot)
    #expect(!plot.topics.contains("endgame vision"))
    #expect(plot.purpose.contains("only where the author has given them"))
  }

  @Test func shouldMaterializeTheCastThePowerSystemTheWorldAndItsFactionsAsRecords() {
    #expect(chapterForStage(.characters).materializes.contains(.character))
    #expect(chapterForStage(.power).materializes.contains(.powerRule))
    #expect(chapterForStage(.factionsAndLocations).materializes.contains(.faction))
    #expect(chapterForStage(.world).materializes.contains(.location))
  }

  @Test func shouldResolveADeclaredAddressAndNotAnAuthorNamedSlug() {
    #expect(chapterAt(section: "power", slug: "system-and-limits")?.stage == .power)
    #expect(chapterAt(section: "power", slug: "supers-and-rifts") == nil)
  }

  @Test func shouldUnionTheTypesEveryChapterInTheSectionMaterializesInManifestOrder() {
    #expect(entityTypesForSection("world") == [.location, .concept, .faction])
  }

  @Test func shouldReportASectionThatMaterializesNothingAsNotEntityBearing() {
    #expect(entityTypesForSection("story_state").isEmpty)
    #expect(!isEntityBearingSection("story_state"))
  }

  @Test func shouldTreatPowerAsEntityBearingSoAnAuthorNamedPowerDocumentIsStillHeldToRecords() {
    #expect(isEntityBearingSection("power"))
  }

  @Test func shouldHoldADeclaredChapterToItsOwnTypes() {
    #expect(requiredEntityTypesForSlug(section: "project", slug: "cast") == [.character])
    #expect(requiredEntityTypesForSlug(section: "project", slug: "premise").isEmpty)
  }

  @Test func shouldHoldAnAuthorNamedSlugInAnAllRecordSectionToTheSectionsTypes() {
    #expect(Set(requiredEntityTypesForSlug(section: "power", slug: "supers-and-rifts")) == [.concept, .powerRule])
  }

  @Test func shouldExemptAnAuthorNamedSlugInASectionThatMixesRecordAndProseChapters() {
    #expect(requiredEntityTypesForSlug(section: "project", slug: "reader-promise").isEmpty)
  }

  @Test func shouldExemptASectionTheManifestNeverDeclares() {
    #expect(requiredEntityTypesForSlug(section: "lore", slug: "anything").isEmpty)
  }

  @Test func shouldNameADeclaredStageForEveryLegacyAddressAndMoveEachRow() {
    for legacy in legacyChapterSlugs {
      let chapter = chapterForStage(legacy.stage)
      #expect("\(legacy.section.rawValue)/\(legacy.slug)" != "\(chapter.section.rawValue)/\(chapter.slug)")
    }
    #expect(legacyChapterSlugs.contains { $0.section == .ai })
    #expect(!bibleManifest.contains { $0.section == .ai })
  }

  @Test func shouldStateTheRecordTypesAndTopicsForEachChapterAsGuidanceNotAQuota() {
    let rendered = renderManifest()
    #expect(rendered.contains("power/system-and-limits"))
    #expect(rendered.contains("recorded as entities of type: power_rule, concept"))
    #expect(rendered.contains("topics to cover where the author's material supports them: progression ladder; costs and limits"))
    #expect(rendered.range(of: #"at least \d|must cover"#, options: .regularExpression) == nil)
  }

  @Test func shouldNotClaimAnEntityRequirementForAChapterThatMaterializesNothing() throws {
    let line = try #require(renderManifest().split(separator: "\n").first { $0.hasPrefix("story_state/volume-plan") })
    #expect(!line.contains("recorded as entities"))
  }

  @Test func shouldMatchSlugsByCodeUnitsNotCanonicalEquivalence() {
    #expect(chapterAt(section: "project", slug: "cast") != nil)
    #expect(chapterAt(section: "project", slug: "cas\u{74}") != nil)
    #expect(requiredEntityTypesForSlug(section: "power", slug: "e\u{301}") == requiredEntityTypesForSlug(section: "power", slug: "\u{E9}"))
  }
}
