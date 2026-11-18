import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

/// A random novel whose withheld material is written verbatim into every field the writer could read: secrets (one gated by an unreached milestone, one the
/// ending contract forbids resolving), the ending and its question, later volumes' goals and bodies, planner-only pages, isolated chapters and a later draft.
private struct LeakWorld {
  static let futureMarker = "FUTUREDRAFTMARKER"

  var world = WriterPackWorld()
  var chapter = 1
  var isolatedMarkers: [String] = []
  var endingText = ""
  var endingQuestionText = ""
  var gated = "f_gated"
  var forbidden = ""

  init(_ generator: inout SeededGenerator) {
    chapter = Int.random(in: 1...7, using: &generator)
    endingText = "ENDINGMARKER the harbour floods at last."
    endingQuestionText = "ENDQUESTIONMARKER will the lamp hold through winter?"
    world.ending = Bool.random(using: &generator) ? endingText : nil
    world.endingQuestion = Bool.random(using: &generator) ? endingQuestionText : nil
    let volumes = Int.random(in: 0...3, using: &generator)
    world.volumes = (0..<volumes).map { index in
      WriterPackVolume(
        volume: "v\(index + 1)", ordinal: index + 1, title: "Volume \(index + 1)", objective: "VOLGOAL\(index + 1) the town rises \(index + 1) times.",
        body: Bool.random(using: &generator) ? "VOLBODY\(index + 1) the cellar ledger burns." : nil, goalMet: Bool.random(using: &generator))
    }
    let planted = [endingText, endingQuestionText] + world.volumes.flatMap { [$0.objective, $0.body].compactMap(\.self) }
    let entities = (0..<Int.random(in: 1...5, using: &generator)).map { "e\($0)" }
    var facts: [DisclosureFact] = []
    for index in 0..<Int.random(in: 1...5, using: &generator) {
      let reveal: Int? = [nil, 1, chapter, chapter + 1, chapter + 4].randomElement(using: &generator) ?? nil
      facts.append(
        DisclosureFact(
          factKey: "f\(index)", text: "SECRET\(index) the keeper trades memory \(index) for light.",
          writerNote: Bool.random(using: &generator) ? "Keep fact \(index) hidden." : nil,
          terms: Bool.random(using: &generator) ? ["tithe\(index)word"] : nil, subjects: [entities.randomElement(using: &generator) ?? "e0"], source: .manual,
          revealChapter: reveal))
    }
    let unlock = UnlockCondition(validating: .object(OrderedJSONObject([(key: "all", value: .array([.object(OrderedJSONObject([(key: "milestone", value: .string("mx"))]))]))])))
    facts.append(
      DisclosureFact(
        factKey: gated, text: "SECRETGATED the lamp answers only the heir.", terms: ["heirlamp"], source: .manual, revealChapter: 1, unlock: unlock.map(FactUnlock.condition)))
    forbidden = facts.randomElement(using: &generator)?.factKey ?? gated
    world.facts = facts.sorted { JSText.codeUnitPrecedes($0.factKey, $1.factKey) }
    world.milestones = [MilestoneRow(milestoneKey: "mx", state: .open, reachedChapter: nil)]
    world.entities = entities.map { key in
      WriterPackEntity(entity: key, name: "Name \(key)", type: "character", status: "active", body: "Card \(key). \(Self.leaks(facts, planted, &generator))", notes: nil)
    }
    world.knowledge = facts.compactMap { fact in
      guard chapter > 1, fact.factKey != gated, Int.random(in: 0..<4, using: &generator) == 0 else { return nil }
      return KnowledgeRow(
        factKey: fact.factKey, entityKey: entities.randomElement(using: &generator) ?? "e0", learnedInChapter: Int.random(in: 1..<chapter, using: &generator), source: .manual,
        status: .committed)
    }
    world.pages = [
      DisclosurePage(address: BibleDocAddress(section: "project", slug: "timeline"), body: "## Later\n- TIMELINEMARKER the apprentice finds the ledger."),
      DisclosurePage(
        address: BibleDocAddress(section: "lore", slug: "notes"), body: "Copied: TIMELINEMARKER the apprentice finds the ledger. \(Self.leaks(facts, planted, &generator))"),
    ]
    world.writingStyle = "Close third. \(Self.leaks(facts, planted, &generator)) \(endingText)"
    world.ledger = [
      ChatPackLedgerEntry(
        kind: .decision, topic: "voice", statement: "Quiet.", why: nil, rejectedAlternatives: [],
        writerLine: "Line. \(Self.leaks(facts, planted, &generator)) \(endingQuestionText)",
        decidedBy: .author)
    ]
    world.threads = [WriterPackThread(thread: "t0", status: "open", openedChapter: 1, closedChapter: nil, summary: "Thread. \(Self.leaks(facts, planted, &generator))")]
    let volumeKeys = world.volumes.map(\.volume)
    for number in 1...(chapter + 1) {
      let volume = volumeKeys.isEmpty ? nil : volumeKeys[min(volumeKeys.count - 1, (number - 1) / 2)]
      let pov = entities.randomElement(using: &generator)
      let learns =
        number == chapter && Bool.random(using: &generator)
        ? [ContractLearn(KnowledgeReveal(entityKey: pov ?? "e0", factKey: facts.randomElement(using: &generator)?.factKey ?? "f0"))] : []
      let contract = ChapterContract(pov: Bool.random(using: &generator) ? [pov ?? "e0"] : [], learns: learns, isEnding: number == chapter + 1 && Bool.random(using: &generator))
      let refs =
        number == chapter
        ? ["entity:e0", "entity:e1", "thread:t0", "bible_doc:lore/notes", "bible_doc:project/timeline", "chapter:\(max(1, chapter - 1))", "chapter:\(chapter + 1)"]
          + facts.map { "fact:\($0.factKey)" } + volumeKeys.map { "volume:\($0)" } : []
      let ending =
        number == chapter
        ? ChapterEndingContract(
          hookType: .known(.turn), emotionalBeat: Self.leaks(facts, planted, &generator), openQuestion: "Who keeps the lamp?",
          handoffState: Self.leaks(facts, planted, &generator), mustNotResolve: [forbidden]) : nil
      let brief = WriterBriefInput(body: "Plan \(number). \(Self.leaks(facts, planted, &generator))", pov: pov, endingContract: ending)
      world.plans.append(WriterPackPlan(chapter: number, volume: volume, pov: pov, contextRefs: refs, contract: contract, endingContract: ending, brief: brief))
    }
    for number in 1..<chapter {
      let isolated = Int.random(in: 0..<3, using: &generator) == 0
      let marker = "ISOLATED\(number)MARKER"
      if isolated { isolatedMarkers.append(marker) }
      let prose = "Prose \(number). \(Self.leaks(facts, planted, &generator))\(isolated ? " \(marker) in the lantern room." : "")"
      let summary = "Summary \(number). \(Self.leaks(facts, planted, &generator))\(isolated ? " \(marker) summary." : "")"
      if Bool.random(using: &generator) {
        world.finals.append(
          WriterPackFinal(chapter: number, title: isolated ? "\(marker) title" : "Title \(number)", body: prose, summary: summary, isolated: isolated, volume: nil))
      }
      if number >= chapter - 3, Bool.random(using: &generator) {
        let state = OrderedJSON.object(
          OrderedJSONObject([
            (key: "establishedFacts", value: .array(facts.map { .string($0.text) })), (key: "location", value: .string(isolated ? marker : "the pier")),
          ]))
        world.drafts.append(
          WriterPackDraft(chapter: number, body: prose, summary: summary, state: state, isolated: isolated, staleReason: Bool.random(using: &generator) ? "stale" : nil))
      }
    }
    let future = "\(Self.futureMarker) the next chapter's prose."
    world.drafts.append(WriterPackDraft(chapter: chapter + 1, body: future, summary: future, state: .string(future), isolated: false, staleReason: nil))
  }

  private static func leaks(_ facts: [DisclosureFact], _ planted: [String], _ generator: inout SeededGenerator) -> String {
    let secrets = facts.filter { _ in Bool.random(using: &generator) }.map { "\($0.text) The \($0.terms?.first ?? "lamp") stirs." }
    return (secrets + planted.filter { _ in Bool.random(using: &generator) }).joined(separator: " ")
  }
}

struct WriterPackPropertyTests {
  @Test func shouldNeverHandTheWriterWhatItsDisclosurePolicyWithholds() throws {
    var generator = SeededGenerator(seed: 0x6715_2026)
    var checked = (packs: 0, locked: 0, isolated: 0)
    for _ in 0..<120 {
      let leak = LeakWorld(&generator)
      let permissive = Int.random(in: 0..<4, using: &generator) == 0
      let budget = [24_000, 6_000, 2_500].randomElement(using: &generator) ?? 24_000
      let (pack, disclosure) = try WriterPackAssembler.assemble(leak.world, chapter: leak.chapter, options: WriterPackOptions(budgetTokens: budget, permissive: permissive))
      let texts = [pack.rendered, pack.brief.chapterBrief, pack.brief.endingContract]
      let label = "chapter \(leak.chapter)\(permissive ? " permissive" : "")"
      checked.packs += 1
      let locked = Set(disclosure.lockedFacts.map(\.factKey))
      #expect(locked.contains(leak.gated) && locked.contains(leak.forbidden), "\(label): the gated or forbidden fact was not locked")
      for text in texts { #expect(!text.contains(LeakWorld.futureMarker), "\(label): a later chapter's draft leaked") }
      for fact in disclosure.lockedFacts {
        checked.locked += 1
        for text in texts {
          #expect(!text.contains(fact.text), "\(label): \(fact.factKey) leaked")
          #expect(!text.contains("SECRET\(fact.factKey == leak.gated ? "GATED" : String(fact.factKey.dropFirst())) "), "\(label): \(fact.factKey) marker leaked")
        }
        #expect(try scanKnowledgeLeaks(pack.rendered, hidden: [fact]).isEmpty, "\(label): \(fact.factKey) term leaked")
      }
      let atEnding = leak.world.plan(for: leak.chapter)?.contract.isEnding == true || leak.world.plans.contains { $0.contract.isEnding && $0.chapter <= leak.chapter }
      let current = leak.world.plan(for: leak.chapter)?.volume.flatMap { key in leak.world.volumes.first { $0.volume == key }?.ordinal }
      for text in texts {
        if !atEnding {
          #expect(!text.contains("ENDINGMARKER") || leak.world.ending == nil, "\(label): the ending leaked")
          #expect(!text.contains("ENDQUESTIONMARKER") || leak.world.endingQuestion == nil, "\(label): the ending question leaked")
        }
        for volume in leak.world.volumes where current.map({ volume.ordinal > $0 }) ?? true {
          #expect(!text.contains("VOLGOAL\(volume.ordinal) "), "\(label): later volume \(volume.volume)'s goal leaked")
          #expect(!text.contains("VOLBODY\(volume.ordinal) "), "\(label): later volume \(volume.volume)'s body leaked")
        }
      }
      #expect(!text(pack, "ref:bible_doc:lore/notes").contains("TIMELINEMARKER"), "\(label): a planner-only page leaked")
      #expect(!pack.sections.contains { $0.key == "ref:bible_doc:project/timeline" }, "\(label): a planner-only page was cited")
      if !permissive {
        for marker in leak.isolatedMarkers {
          checked.isolated += 1
          #expect(!pack.rendered.contains(marker), "\(label): isolated \(marker) reached a standard writer")
        }
      }
    }
    #expect(checked.locked > 100 && checked.isolated > 30)
  }

  @Test func shouldKeepEveryRequiredSectionWhateverTheBudget() throws {
    var generator = SeededGenerator(seed: 0x6715_0001)
    for _ in 0..<30 {
      let leak = LeakWorld(&generator)
      let pack = try WriterPackAssembler.assemble(leak.world, chapter: leak.chapter, options: WriterPackOptions(budgetTokens: 1_000)).pack
      #expect(pack.sections.filter(\.required).count == pack.reservations.count - 1)
      #expect(pack.rendered.hasPrefix(pack.renderedStable))
    }
  }
}

private func text(_ pack: WriterPack, _ key: String) -> String {
  pack.sections.first { $0.key == key }?.rendered ?? ""
}
