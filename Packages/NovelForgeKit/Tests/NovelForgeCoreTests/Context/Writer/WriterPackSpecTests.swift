import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private func scenario(_ name: String) throws -> WriterPackFixture.Spec {
  try #require(try WriterPackFixture.shared.get().scenarios.first { $0.spec.name == name }).spec
}

private func assembled(_ name: String) throws -> (pack: WriterPack, disclosure: WriterDisclosurePolicy) {
  let spec = try scenario(name)
  return try WriterPackAssembler.assemble(try spec.world(), chapter: spec.chapter, options: spec.options)
}

private func text(_ pack: WriterPack, _ key: String) -> String {
  pack.sections.first { $0.key == key }?.rendered ?? ""
}

// apps/novel-forge-server/tests/ai/chapter-pack.spec.ts, over the same novel with every query honoured
struct WriterPackChapterSpecTests {
  @Test func shouldRenderThePovCardWholeAndInAuthoredOrder() throws {
    let pack = try assembled("chapter pack").pack
    let pov = try #require(pack.sections.first { $0.key == "ref:entity:wren" })
    #expect(pov.rendered.contains("POV_CARD_LAST_PARAGRAPH"))
    #expect(pov.rendered.hasPrefix("## POV CHARACTER: Wren Aldous"))
    #expect(!pov.truncated)
    #expect(pov.required && pov.segment == .stable)
  }

  @Test func shouldCapOtherCardsWhileKeepingTheirGuidanceFirst() throws {
    let card = try #require(try assembled("chapter pack").pack.sections.first { $0.key == "ref:entity:tobin" })
    #expect(card.truncated)
    #expect(card.rendered.contains("SIDE_CARD_CAUTION_MARKER") && card.rendered.contains("SIDE_CARD_PROHIBITION_MARKER"))
    #expect(!card.rendered.contains("SIDE_CARD_LAST_DESCRIPTION"))
    #expect(card.rendered.jsIndexOf("SIDE_CARD_CAUTION_MARKER") < card.rendered.jsIndexOf("Paragraph 0."))
    #expect(countTokens(card.rendered) <= WriterPackRender.entityCardBudget + 40)
  }

  @Test func shouldKeepACardThatFitsInItsAuthoredOrder() throws {
    let card = try #require(try assembled("chapter pack").pack.sections.first { $0.key == "ref:entity:harbor_guild" })
    #expect(card.rendered == "## FACTION: Harbor Guild\n\n**Harbor Guild** (faction, active)\nKeeps the tide tables.\nStatus: active")
    #expect(!card.truncated)
  }

  @Test func shouldHeadEveryResolvedRefWithAReadableLabel() throws {
    let pack = try assembled("chapter pack").pack
    #expect(!pack.rendered.contains("## REF:"))
    for label in ["## CHARACTER: Tobin Reyes", "## WORLD FACTS: harbor_customs", "## BIBLE: world/harbor", "## VOLUME OBJECTIVE"] {
      #expect(pack.rendered.contains(label), "\(label)")
    }
  }

  @Test func shouldResolveAVolumeRefOnceToItsGoalAndLeaveAnArcUnresolved() throws {
    var disclosure = WriterDisclosurePolicy.planner
    let world = try scenario("chapter pack").world()
    let resolution = try world.resolveRefs(["volume:volume_tides", "volume:volume_tides", "volume:volume_missing", "arc:arc_opening"], chapter: 1, disclosure: &disclosure)
    #expect(resolution.resolved.map(\.key) == ["ref:volume:volume_tides"])
    #expect(resolution.resolved.first?.rendered.contains("Goal: VOLUME_REF_OBJECTIVE") == true)
    #expect(resolution.resolved.first?.tier == .approvedIntent)
    #expect(resolution.unresolved == ["volume:volume_missing", "arc:arc_opening"])
  }

  @Test func shouldLeaveTheCurrentVolumesRefToItsObjectiveSection() throws {
    let pack = try assembled("chapter pack").pack
    #expect(text(pack, "volume_objective").contains("VOLUME_REF_OBJECTIVE"))
    #expect(!pack.sections.contains { $0.key == "ref:volume:volume_tides" })
    #expect(pack.unresolvedRefs.contains("volume:volume_missing") && pack.unresolvedRefs.contains("arc:arc_opening"))
  }

  @Test func shouldResolveWorldFactsByCategoryKeyAndCategorySlashKey() throws {
    let pack = try assembled("chapter pack").pack
    let byCategory = text(pack, "ref:world_fact:harbor_customs")
    #expect(byCategory.contains("bell_curfew: No boat leaves after the third bell.") && byCategory.contains("tithe_scale: Every tenth crate goes to the guild."))
    #expect(text(pack, "ref:world_fact:fog_season").contains("weather/fog_season: Fog holds the bay"))
    #expect(text(pack, "ref:world_fact:weather/fog_season").contains("weather/fog_season: Fog holds the bay"))
    #expect(pack.unresolvedRefs.contains("world_fact:harbor_customs/missing"))
  }

  @Test func shouldTellChapterOneThatThePovCastKnowsNothingYet() throws {
    #expect(text(try assembled("chapter pack").pack, "known_facts").contains("no ledgered facts"))
  }

  @Test func shouldKeepTheStyleGuideAndReportWhatTheBudgetCut() throws {
    let pack = try assembled("chapter pack over budget").pack
    #expect(text(pack, "writing_style").contains("WRITING_STYLE_MARKER"))
    #expect(pack.omitted.contains { $0.key == "ref:bible_doc:world/ledger" })
    #expect(pack.usedTokens <= max(pack.budgetTokens, pack.sections.filter(\.required).reduce(0) { $0 + $1.tokens }))
  }

  @Test func shouldCapOversizedAdditionsKeepingTheDefaultsWhole() throws {
    let pack = try assembled("chapter pack oversized style").pack
    let style = try #require(pack.sections.first { $0.key == "writing_style" })
    #expect(style.truncated)
    #expect(style.rendered.contains(defaultWritingInstructions) && style.rendered.contains("WRITING_STYLE_MARKER"))
    #expect(style.tokens <= WriterRender.writingStyleBudget + 10)
    #expect(pack.sections.contains { $0.key == "ref:entity:wren" })
  }

  @Test func shouldReportUnresolvedRefsAndCutsForACrowdedCast() throws {
    let pack = try assembled("chapter pack crowded cast").pack
    for ref in ["volume:volume_missing", "world_fact:harbor_customs/missing", "nocolon", "unknown:thing"] { #expect(pack.unresolvedRefs.contains(ref), "\(ref)") }
    #expect(pack.omitted.contains { $0.key == "ref:bible_doc:world/ledger" })
  }

  @Test func shouldCarryTheWriterLinesDirectlyAheadOfTheBrief() throws {
    let pack = try assembled("chapter pack decisions").pack
    let lines = try #require(pack.sections.first { $0.key == "writer_lines" })
    #expect(
      lines.rendered
        == "## AUTHOR DECISIONS FOR THE WRITER\n\n- WRITER_LINE_MARKER Wren checks the numbers before she answers anyone.\n- Tobin jokes when the crew is scared.")
    #expect(lines.segment == .volatile)
    #expect(pack.renderedVolatile.hasSuffix(lines.rendered))
    #expect(!pack.rendered.contains("DIRECTION_MARKER"))
    #expect(text(try assembled("chapter pack decisions over budget").pack, "writer_lines").contains("WRITER_LINE_MARKER"))
    #expect(!(try assembled("chapter pack").pack.sections.contains { $0.key == "writer_lines" }))
  }

  @Test func shouldPinTheStableSectionsAheadOfTheVolatileOnes() throws {
    let pack = try assembled("chapter pack").pack
    let stable = pack.sections.filter { $0.segment == .stable }
    #expect(!stable.isEmpty)
    #expect(pack.rendered.hasPrefix(pack.renderedStable))
    #expect(pack.renderedStable == joinSections(stable))
    #expect(stable.allSatisfy { $0.key.hasPrefix("ref:") || ["volume_objective", "completed_volumes", "open_canon", "writing_style"].contains($0.key) })
  }

  @Test func shouldFeedTheGenerationPromptTheStablePrefixFirst() throws {
    let pack = try assembled("writer disclosure locked vault").pack
    let input = pack.generationInput(guidance: "Tighten the pier.")
    #expect(input.stableContext == pack.renderedStable && input.volatileContext == pack.renderedVolatile)
    #expect(input.chapterBrief == pack.brief.chapterBrief && input.endingContract == pack.brief.endingContract)
  }

  @Test func shouldKeepTheStablePrefixWhenOnlyVolatileMaterialChanges() throws {
    let spec = try scenario("writer disclosure locked vault")
    var world = try spec.world()
    let before = try WriterPackAssembler.assemble(world, chapter: spec.chapter).pack
    world.drafts = world.drafts.map { draft in
      var changed = draft
      changed.summary = "A different summary of the day."
      changed.body = "Different closing prose."
      return changed
    }
    world.ledger.append(ChatPackLedgerEntry(kind: .decision, topic: "new", statement: "New.", why: nil, rejectedAlternatives: [], writerLine: "A new line.", decidedBy: .author))
    let after = try WriterPackAssembler.assemble(world, chapter: spec.chapter).pack
    #expect(after.renderedStable == before.renderedStable)
    #expect(after.renderedVolatile != before.renderedVolatile)
  }
}

private let truth = "The keeper trades one memory for every hour the lamp burns."
private let term = "memory tithe"
private let key = "lamp_memory_price"
private let clue = "The keeper forgets small names after a long night."
private let ending = "The keeper lets the lamp go dark and the harbour floods."
private let endingQuestion = "Will the keeper keep the harbour lit through winter?"
private let secondGoal = "The apprentice learns to light the lamp alone."
private let thirdGoal = "The drowned town rises to claim its keeper at last."
private let timelineLine = "The apprentice discovers the ledger of lost names in the cellar."
private let openQuestion = "Does the apprentice ever learn who built the lamp?"
private let payload = [truth, "Villagers whisper of the \(term).", "See \(key).", ending, endingQuestion, secondGoal, thirdGoal, timelineLine, openQuestion, clue].joined(
  separator: " ")
private let factMarkers = [truth, term, key]
private let plannedMarkers = [ending, endingQuestion, secondGoal]
private let pageMarkers = [timelineLine, openQuestion]

private struct WriterField: Sendable {
  let name: String
  let read: @Sendable (WriterPack, inout WriterDisclosurePolicy) throws -> String
  let copies: Bool
  let payload: Bool
  let vault: Bool
}

private func field(_ name: String, _ key: String, copies: Bool = false, payload: Bool = true, vault: Bool = true) -> WriterField {
  WriterField(name: name, read: { pack, _ in text(pack, key) }, copies: copies, payload: payload, vault: vault)
}

// apps/novel-forge-server/tests/ai/writer-disclosure-pack.spec.ts:56-80, less the plugin section
private let writerFields: [WriterField] = [
  field("previous prose ending", "prev_ending"),
  field("continuation state", "continuation_state"),
  field("recent summaries", "memory"),
  field("current volume objective", "volume_objective", payload: false),
  field("known facts", "known_facts"),
  field("this chapter's reveals", "chapter_reveals"),
  field("hidden-fact writer notes", "hidden_constraints", payload: false),
  field("POV entity sheet", "ref:entity:keeper", copies: true),
  field("cited entity sheet and its alias", "ref:entity:apprentice", copies: true),
  field("character state", "character_state", vault: false),
  field("relationships", "relationships", vault: false),
  field("cited world facts", "ref:world_fact:lamps", copies: true, vault: false),
  field("cited plot thread", "ref:thread:harbour_debt", copies: true),
  field("cited mystery", "ref:mystery:lamp_builder", copies: true),
  field("cited earlier chapter and its heading", "ref:chapter:4"),
  field("cited canon fact", "ref:fact:harbour_rule"),
  field("renamed page holding copied secrets", "ref:bible_doc:lore/harbour-notes", copies: true),
  field("writing style", "writing_style"),
  field("writer lines", "writer_lines"),
  WriterField(name: "chapter brief", read: { pack, _ in pack.brief.chapterBrief }, copies: false, payload: true, vault: true),
  WriterField(name: "ending contract", read: { pack, _ in pack.brief.endingContract }, copies: false, payload: false, vault: true),
  WriterField(
    name: "feedback, guidance and findings", read: { _, disclosure in try disclosure.scrub("[soft] brief: tighten the pier. \(payload)", .note) }, copies: false, payload: true,
    vault: true),
]

struct WriterPackDisclosureSpecTests {
  private static let worlds = ["writer disclosure locked", "writer disclosure locked vault"]

  @Test func shouldKeepALockedSecretTheEndingAndLaterVolumesOutOfEveryWriterField() throws {
    for name in Self.worlds {
      let (pack, policy) = try assembled(name)
      var disclosure = policy
      for row in writerFields where row.vault || !name.hasSuffix("vault") {
        let text = try row.read(pack, &disclosure)
        #expect(!text.isEmpty, "\(name) \(row.name)")
        #expect(text.contains("[withheld]"), "\(name) \(row.name)")
        for marker in factMarkers + plannedMarkers + [thirdGoal] { #expect(!text.contains(marker), "\(name) \(row.name): \(marker)") }
        for marker in pageMarkers where row.copies || row.payload { #expect(text.contains(marker) == !row.copies, "\(name) \(row.name): \(marker)") }
      }
    }
  }

  @Test func shouldHandOverTheUnlockedSecretTheEndingAndTheCurrentVolume() throws {
    for name in ["writer disclosure unlocked", "writer disclosure unlocked vault"] {
      let (pack, policy) = try assembled(name)
      var disclosure = policy
      for row in writerFields where row.payload && (row.vault || !name.hasSuffix("vault")) {
        let text = try row.read(pack, &disclosure)
        for marker in factMarkers + plannedMarkers { #expect(text.contains(marker), "\(name) \(row.name): \(marker)") }
        #expect(!text.contains(thirdGoal), "\(name) \(row.name)")
        for marker in pageMarkers { #expect(text.contains(marker) == !row.copies, "\(name) \(row.name): \(marker)") }
      }
    }
  }

  @Test func shouldKeepAnOpeningTimelineLineThePlanQuotesAndWithholdItFromACopy() throws {
    let pack = try assembled("writer disclosure locked").pack
    #expect(pack.brief.chapterBrief.contains(timelineLine))
    #expect(!text(pack, "ref:bible_doc:lore/harbour-notes").contains(timelineLine))
  }

  @Test func shouldListAllowedCluesForALockedSecretOnly() throws {
    let (locked, policy) = try assembled("writer disclosure locked")
    var disclosure = policy
    for row in writerFields where row.payload { #expect(try row.read(locked, &disclosure).contains(clue), "\(row.name)") }
    #expect(text(locked, "allowed_clues").contains("- \(clue)"))
    #expect(text(try assembled("writer disclosure unlocked").pack, "allowed_clues").isEmpty)
  }

  @Test func shouldReportRefusedRefsAsWithheldApartFromMissingOnes() throws {
    let locked = try assembled("writer disclosure locked").pack
    let unlocked = try assembled("writer disclosure unlocked").pack
    let refused = [
      "bible_doc:project/open-questions", "bible_doc:project/timeline", "bible_doc:story_state/volume-plan", "chapter:7", "thread:winter_debt", "volume:v3",
    ]
    #expect(locked.unresolvedRefs == ["entity:ghost"])
    #expect(locked.withheldRefs.sorted() == (refused + ["volume:v2"]).sorted())
    #expect(unlocked.withheldRefs.sorted() == refused)
    #expect(text(unlocked, "ref:volume:v2").isEmpty)
    #expect(text(unlocked, "volume_objective").contains(secondGoal))
    #expect(text(locked, "ref:volume:v1").isEmpty)
    #expect(text(locked, "volume_objective").contains("[withheld]"))
  }

  @Test func shouldDropAnEstablishedFactCarryingALockedTermFromTheContinuationState() throws {
    for name in Self.worlds {
      let state = text(try assembled(name).pack, "continuation_state")
      #expect(state.contains("The pier is rotten."), "\(name)")
      #expect(!state.contains("is paid"), "\(name)")
    }
  }
}

private let isolatedMarker = "ISOLATED_PROSE_MARKER"

struct WriterPackIsolationSpecTests {
  @Test func shouldLeaveIsolatedProseSummariesAndStateOutOfAStandardPack() throws {
    for name in ["isolated chapters standard", "isolated final ending standard"] {
      let pack = try assembled(name).pack
      #expect(!pack.rendered.contains(isolatedMarker), "\(name)")
      #expect(pack.rendered.contains(ChatPack.noApprovedBridge) || pack.rendered.contains(ChatPack.noBridgeSummary), "\(name)")
      #expect(!pack.sections.contains { $0.key == "continuation_state" }, "\(name)")
    }
  }

  @Test func shouldReadIsolatedChaptersAsWrittenOnThePermissiveRoute() throws {
    let pack = try assembled("isolated chapters permissive").pack
    #expect(text(pack, "prev_ending").contains(isolatedMarker))
    #expect(text(pack, "continuation_state").contains(isolatedMarker))
    #expect(text(pack, "memory").contains(isolatedMarker))
    #expect(!text(pack, "completed_volumes").contains(isolatedMarker))
    #expect(!text(pack, "ref:chapter:2").contains(isolatedMarker))
  }

  @Test func shouldDeclineAPermissivePackThatCrossesTheHardLine() throws {
    let spec = try scenario("isolated chapters permissive")
    var world = try spec.world()
    world.drafts[world.drafts.count - 1].summary = "A note about the loli figurine."
    #expect(throws: WriterPackError.self) { try WriterPackAssembler.assemble(world, chapter: spec.chapter, options: spec.options) }
    do {
      _ = try WriterPackAssembler.assemble(world, chapter: spec.chapter, options: spec.options)
    } catch {
      #expect(error.code == "AI_015")
    }
    #expect((try? WriterPackAssembler.assemble(world, chapter: spec.chapter, options: WriterPackOptions())) != nil)
  }
}

struct WriterPackVaultTests {
  @Test func shouldRefuseThePackWhenASecretCannotBeRead() async throws {
    let spec = try scenario("writer disclosure locked vault")
    let store = try await WriterPackVault.build(spec)
    try await ReadWorld.write(store) { transaction in
      let ref = SecretRecord(novel: WriterPackVault.novel, secret: key, text: "").ref
      _ = try transaction.set(ref, [SecretField.text.rawValue: .int(3)])
    }
    let load = try await WriterPackVault.load(store, chapter: spec.chapter)
    #expect(load.unreadable == [.secrets])
    await #expect(throws: WriterPackError.self) { try await store.writerPack(novel: WriterPackVault.novel, chapter: spec.chapter) }
  }

  @Test func shouldReadAFinalChaptersClaimsFromItsCanon() async throws {
    let spec = try scenario("isolated chapters standard")
    let store = try await WriterPackVault.build(spec)
    try await ReadWorld.write(store) { transaction in
      let ref = try ChapterPlanRecord.ref(novel: WriterPackVault.novel, chapter: 1)
      _ = try ChapterPlanRecord.revise(ref, ChapterPlanContent(body: "Replanned.", volume: "v2"), in: &transaction)
    }
    let world = try await WriterPackVault.load(store, chapter: 5).world
    #expect(world.plan(for: 1)?.volume == "v1")
    #expect(world.plan(for: 1)?.brief.body == "Replanned.")
  }

  @Test func shouldScreenAPermissivePackWithTheNovelsMinorNames() async throws {
    let spec = try scenario("isolated chapters permissive")
    let store = try await WriterPackVault.build(spec)
    try await ReadWorld.write(store) { transaction in
      _ = try EntityRecord(novel: WriterPackVault.novel, entity: "tamsin", type: .known(.character), name: "Tamsin", age: 12).create(in: &transaction)
      var edit = NovelEdit()
      edit.writingStyle = .set("Close third. Tamsin and the orgasm.")
      _ = try NovelRecord.edit(id: WriterPackVault.novel, edit, in: &transaction)
    }
    do {
      _ = try await store.writerPack(novel: WriterPackVault.novel, chapter: spec.chapter, options: spec.options)
      Issue.record("a minor's name beside an explicit act reached the permissive writer")
    } catch {
      #expect(error.code == "AI_015")
    }
    let standard = try await store.writerPack(novel: WriterPackVault.novel, chapter: spec.chapter).pack
    #expect(standard.sections.contains { $0.key == "writing_style" })
    let world = try await WriterPackVault.load(store, chapter: spec.chapter)
    #expect(world.minorNames == ["Tamsin"])
    #expect((try? WriterPackAssembler.assemble(world.world, chapter: spec.chapter, options: spec.options)) != nil)
  }

  @Test func shouldEnforceTheReservationsOnlyWhenAsked() async throws {
    let spec = try scenario("budget enforced")
    let store = try await WriterPackVault.build(spec)
    await #expect(throws: WriterPackError.self) { try await store.writerPack(novel: WriterPackVault.novel, chapter: 1, options: spec.options) }
    let pack = try await store.writerPack(novel: WriterPackVault.novel, chapter: 1, options: WriterPackOptions(budgetTokens: spec.budgetTokens)).pack
    #expect(pack.sections.contains { $0.key == "writing_style" })
  }
}
