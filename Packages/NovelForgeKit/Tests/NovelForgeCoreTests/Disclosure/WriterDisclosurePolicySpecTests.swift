import ShadowText
import Testing

@testable import NovelForgeCore

private let ledgerFact = DisclosureFact(
  factKey: "ledger_forgery", text: "The ledger in the study is a forgery planted by Elias.", constraintNote: "Protects the forged-ledger reveal in the study.",
  writerNote: "Elias steers conversation away from the study.", terms: ["forgery", "planted"])
private let debtFact = DisclosureFact(
  factKey: "motive_debt", text: "Marlow owed Elias a ruinous gambling debt.", writerNote: "Elias flinches when gambling is mentioned.", terms: [])

private func policy(
  lockedFacts: [DisclosureFact] = [], plannerOnly: [String] = [], plannerPages: [String] = [], volumeOrdinals: [JSString: Int] = [:], currentVolumeOrdinal: Int? = nil
) throws -> WriterDisclosurePolicy {
  try WriterDisclosurePolicy(
    WriterDisclosureInput(
      chapter: 5, lockedFacts: lockedFacts, plannerOnly: plannerOnly, plannerPages: plannerPages, volumeOrdinals: volumeOrdinals, currentVolumeOrdinal: currentVolumeOrdinal))
}

// Transcribed from apps/novel-forge-server/tests/knowledge/writer-disclosure-policy.spec.ts.
@Suite("WriterDisclosurePolicy")
struct WriterDisclosurePolicySpecTests {
  @Test("should replace leak findings with writer-safe lines and withhold the truth, author note and key")
  func shouldRewriteLeakFindings() throws {
    var disclosure = try policy(lockedFacts: [ledgerFact])
    let note = [
      "[soft] knowledge leak: \"forgery\" exposes [ledger_forgery] — …a forgery…", "[soft] brief: the study scene is skipped",
      "Keep ledger_forgery quiet: The ledger in the study is a forgery planted by Elias. (Protects the forged-ledger reveal in the study.)",
    ].joined(separator: "\n")
    let expected = [
      "[soft] brief: the study scene is skipped", "Keep [withheld] quiet: [withheld]. ([withheld].)",
      "- remove or avoid \"forgery\" — Elias steers conversation away from the study.",
    ].joined(separator: "\n")
    #expect(try disclosure.scrub(note, .note) == expected)
  }

  @Test("should withhold a bare key only when it has an underscore, and a fact: ref always")
  func shouldWithholdKeys() throws {
    var heir = try policy(lockedFacts: [DisclosureFact(factKey: "heir", text: "Mara is the lost heir of the tide court.")])
    var lostHeir = try policy(lockedFacts: [DisclosureFact(factKey: "lost_heir", text: "Mara is the lost heir of the tide court.")])
    #expect(try heir.scrub("Never name the heir or fact:heir. Bring the Heir back.", .summary) == "Never name the heir or [withheld]. Bring the Heir back.")
    #expect(try lostHeir.scrub("Guard lost_heir, not lost_heirloom.", .summary) == "Guard [withheld], not lost_heirloom.")
  }

  @Test("should withhold every give-away term as a whole word, longest first")
  func shouldWithholdTerms() throws {
    var disclosure = try policy(lockedFacts: [ledgerFact])
    let text = "Expose the Forgery; the planted ledger was planted early. The ledger in the study is a forgery planted by Elias. Forgeryless nights."
    #expect(try disclosure.scrub(text, .prose) == "Expose the [withheld]; the [withheld] ledger was [withheld] early. [withheld]. Forgeryless nights.")
  }

  @Test("should match a capitalised term case-sensitively and a lowercase term with Unicode word boundaries")
  func shouldMatchTermCase() throws {
    var will = try policy(lockedFacts: [DisclosureFact(factKey: "will_lives", text: "Will survived the flood.", terms: ["Will"])])
    var court = try policy(lockedFacts: [DisclosureFact(factKey: "tide_court", text: "The court is drowned.", terms: ["tide court", "ox"])])
    #expect(try will.scrub("Will returns, and she will not forgive him.", .biblePage) == "[withheld] returns, and she will not forgive him.")
    #expect(
      try court.scrub("The Tide Court waits; the tide courtiers do not; Ñtide court stays; the ox sleeps.", .entity)
        == "The [withheld] waits; the tide courtiers do not; Ñtide court stays; the ox sleeps.")
  }

  @Test("should withhold a re-wrapped copy and one sentence copied alone")
  func shouldWithholdRewrappedCopies() throws {
    let bell = DisclosureFact(factKey: "bell_price", text: "The bell rings only for the drowned. Each ring costs the ringer a year.")
    var disclosure = try policy(lockedFacts: [bell])
    let scrubbed = try disclosure.scrub("Harbour lore:\nThe bell rings only\n  for the drowned. Later: each ring costs the ringer a year!", .biblePage)
    #expect(scrubbed == "Harbour lore:\n[withheld]. Later: [withheld]!")
  }

  @Test("should leave text alone when nothing is withheld, be stable when run twice and count per field")
  func shouldCount() throws {
    var empty = try policy()
    #expect(try empty.scrub("knowledge leak: anything", .note) == "knowledge leak: anything")
    var twice = try policy(lockedFacts: [ledgerFact, debtFact])
    let once = try twice.scrub("[soft] knowledge leak: [motive_debt] acts on the debt", .note)
    #expect(try twice.scrub(once, .note) == once)
    var counted = try policy(lockedFacts: [ledgerFact])
    _ = try counted.scrub("A forgery.", .summary)
    _ = try counted.scrub("Nothing here.", .heading)
    _ = try counted.scrub("planted and planted", .summary)
    #expect(counted.withheld == [WithheldCount(field: .summary, count: 3)])
  }

  @Test("should withhold planner-only pages only from fields that copy authored canon")
  func shouldWithholdPlannerPages() throws {
    let opening = "Mara arrives at the harbour at dusk"
    let timeline = "## Opening\n- \(opening).\n## Later\n- The apprentice finds the ledger of lost names in the cellar.\n- Short beat."
    var disclosure = try policy(plannerPages: [timeline])
    for field in [WriterField.plan, .writerLine, .note, .style, .prose, .state, .summary] {
      #expect(try disclosure.scrub("\(opening) and meets Tobin.", field) == "\(opening) and meets Tobin.")
    }
    for field in [WriterField.biblePage, .entity, .reference, .plugin] {
      #expect(try disclosure.scrub("\(opening) and meets Tobin. Short beat.", field) == "[withheld] and meets Tobin. Short beat.")
    }
  }

  @Test("should withhold passages of three words or two words and twelve characters, scripts without spaces by length")
  func shouldApplyPassageFloors() throws {
    var disclosure = try policy(
      lockedFacts: [DisclosureFact(factKey: "motive_debt", text: debtFact.text, constraintNote: "None")], plannerOnly: ["He lives on.", "Bittersweet", "None", "Quiet harbour"])
    #expect(try disclosure.scrub("In the end he lives on.", .plan) == "In the end [withheld].")
    #expect(try disclosure.scrub("None of it was bittersweet. Nobody said none.", .summary) == "None of it was bittersweet. Nobody said none.")
    #expect(try disclosure.scrub("They reach the quiet harbour.", .prose) == "They reach the [withheld].")
    var unspaced = try policy(plannerOnly: ["灯塔守护者最终熄灭了灯火", "重逢"])
    #expect(try unspaced.scrub("灯塔守护者最终熄灭了灯火。", .plan) == "[withheld]。")
    #expect(try unspaced.scrub("重逢。", .prose) == "重逢。")
  }

  @Test("should match a copy whose quotes, apostrophes, dashes or emphasis differ")
  func shouldMatchVariants() throws {
    var disclosure = try policy(plannerOnly: ["The keeper's \"last\" lamp — the only one — goes dark."])
    #expect(try disclosure.scrub("Then **the keeper’s** “last” lamp – the only one – goes dark!", .biblePage) == "Then [withheld]!")
  }

  @Test("should scrub state keys and values and drop an established fact carrying a give-away term")
  func shouldScrubState() throws {
    var disclosure = try policy(lockedFacts: [ledgerFact])
    let state = OrderedJSON.object(
      OrderedJSONObject([
        (key: "forgery watch", value: .string("Elias hid the forgery.")),
        (key: "establishedFacts", value: .array([.string("The study was locked."), .string("A forgery sits in the study."), .string("The candles burned out.")])),
        (key: "hp", value: .int(3)),
      ]))
    let expected = OrderedJSON.object(
      OrderedJSONObject([
        (key: "[withheld] watch", value: .string("Elias hid the [withheld].")), (key: "establishedFacts", value: .array([.string("The study was locked.")])),
        (key: "hp", value: .int(3)),
      ]))
    #expect(try disclosure.scrubState(state, establishedFactsMax: 1) == expected)
    let clash = OrderedJSON.object(OrderedJSONObject([(key: "forgery", value: .int(1)), (key: "planted", value: .int(2))]))
    #expect(
      try disclosure.scrubState(clash, establishedFactsMax: 5) == .object(OrderedJSONObject([(key: "[withheld]", value: .int(1)), (key: "[withheld] (2)", value: .int(2))])))
  }

  @Test("should resolve current and earlier volumes, earlier chapters, and no planner-only or writer-excluded page")
  func shouldGateReferences() throws {
    let volumes: [JSString: Int] = ["v1": 1, "v2": 2, "v3": 3]
    let current = try policy(volumeOrdinals: volumes, currentVolumeOrdinal: 2)
    #expect(["volume:v1", "volume:v2", "volume:v3", "volume:missing"].map(current.canResolve) == [true, true, false, true])
    #expect(try policy(volumeOrdinals: volumes).canResolve("volume:v1") == false)
    let disclosure = try policy()
    #expect(["chapter:4", "chapter:5", "chapter:9", "chapter:x"].map(disclosure.canResolve) == [true, false, false, false])
    for doc in ["project/timeline", "project/open-questions", "story_state/volume-plan", "story_state/volumes", "plot/escalation-map"] {
      #expect(!disclosure.canResolve("bible_doc:\(doc)"))
    }
    #expect(disclosure.canResolve("bible_doc:project/premise"))
    #expect(disclosure.canResolve("entity:mira"))
    #expect([3, 5, 6, nil].map(disclosure.opensBy) == [true, true, false, true])
  }

  @Test("should list each leak with its writer note, withhold nothing as the planner, and drop a clue naming a term")
  func shouldListLeaksAndClues() throws {
    var disclosure = try policy(lockedFacts: [ledgerFact])
    #expect(try disclosure.leakLines("She found the forgery.") == ["- remove or avoid \"forgery\" — Elias steers conversation away from the study."])
    #expect(try disclosure.leakLines("She found the ledger.") == [])
    var planner = WriterDisclosurePolicy.planner
    #expect(try planner.scrub("A forgery planted by Elias.", .plan) == "A forgery planted by Elias.")
    #expect(["volume:v9", "chapter:900", "bible_doc:project/timeline"].allSatisfy(planner.canResolve))
    var clued = ledgerFact
    clued.allowedClues = ["Ink smudges on the ledger.", "Ink smudges on the forgery.", " ", "Elias avoids the study."]
    var debt = debtFact
    debt.allowedClues = ["Elias avoids the study."]
    #expect(try policy(lockedFacts: [clued, debt]).allowedClues() == ["Ink smudges on the ledger.", "Elias avoids the study."])
    #expect(
      try cluesNamingTerms(["Will waits by the door", "she will wait", "a cold draught"], ["Will", "draught", "ox"]) == [
        "\"Will waits by the door\" names \"Will\"", "\"a cold draught\" names \"draught\"",
      ])
  }
}

// Behaviour the reference cannot show or that this port settles differently; each case discloses no more than the reference would.
@Suite("WriterDisclosurePolicy deviations")
struct WriterDisclosurePolicyDeviationTests {
  private let heir = DisclosureFact(factKey: "heir", text: "Mara is the lost heir.", writerNote: "Keep calm.", terms: ["lost heir"])

  @Test("should refuse a writer note whose leak finding cites its own fact, where the reference overflows its stack")
  func shouldRefuseLeakFindingCycle() throws {
    let loop = DisclosureFact(factKey: "loop_fact", text: "The loop is endless.", writerNote: "knowledge leak: loop_fact again", terms: ["loop"])
    var disclosure = try policy(lockedFacts: [loop])
    #expect(throws: DisclosureError.leakFindingCycle) { try disclosure.scrub("knowledge leak: the cast names loop_fact", .note) }
  }

  @Test("should follow the reference's offset arithmetic when a capital İ before the prefix lowers to two code units")
  func shouldSliceFindingsAsTheReference() throws {
    var disclosure = try policy(lockedFacts: [heir])
    let unknowable = "- cut anything that states or implies what the POV cast cannot know yet — Keep calm."
    let solved = "- leave the clues unexplained: cut the narration, dialogue or action that links them to a conclusion the POV cast has not discovered on-page — Keep calm."
    #expect(try disclosure.scrub("İknowledge leak: 😀 over-connection: heir", .note) == unknowable)
    #expect(try disclosure.scrub("İknowledge leak: x over-connection: heir", .note) == solved)
    #expect(try disclosure.scrub("İİknowledge leak: 😀\"lost heir\" exposes [heir]", .note) == "- remove or avoid \"lost heir\" — Keep calm.")
  }

  @Test("should drop the half of a surrogate pair an excerpt cuts, which the reference keeps as a lone code unit")
  func shouldDropHalfPairInExcerpt() throws {
    let issues = try scanKnowledgeLeaks(String(repeating: "😀", count: 31) + " lost heir", hidden: [heir])
    #expect(issues.first?.excerpt.jsStartsWith("…😀") == true)
    #expect(issues.first?.excerpt.jsLength == 1 + (72 - 3) - 1)
  }
}
