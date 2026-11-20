import Foundation
import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

private let ending = "The keeper floods the valley to save the town."
private let endingQuestion = "Will the harbour outlast the flood season?"

private func plan(_ chapter: Int, isEnding: Bool = false, volumeKey: String? = nil, contract: OrderedJSON = .null) -> DisclosurePlan {
  DisclosurePlan(
    unnormalized: PlanRow(claims: PlanClaims(chapter: chapter, volumeKey: volumeKey, isEnding: isEnding, claimedMilestones: nil), knowledgeContract: contract),
    endingContract: .null)
}

private func learns(pov: String, _ pairs: [(entity: String, fact: String)]) -> OrderedJSON {
  let entries = pairs.map { OrderedJSON.object(OrderedJSONObject([(key: "entityKey", value: .string($0.entity)), (key: "factKey", value: .string($0.fact))])) }
  return .object(OrderedJSONObject([(key: "pov", value: .array([.string(pov)])), (key: "learns", value: .array(entries))]))
}

private func contract(pov: String, learns: [String] = []) -> KnowledgeContract {
  KnowledgeContract(pov: [pov], learns: learns.map { KnowledgeReveal(entityKey: pov, factKey: $0) })
}

@Suite("Knowledge view and writer sources")
struct KnowledgeViewSpecTests {
  // Transcribed from apps/novel-forge-server/tests/bible/art-disclosure-policy.spec.ts.
  @Test("should withhold the ending from art drawn at the ending chapter while its writer may read it")
  func shouldWithholdEndingFromArt() throws {
    let world = DisclosureWorld(ending: ending, endingQuestion: endingQuestion, plans: [plan(9, isEnding: true)])
    var art = try artDisclosurePolicy(in: world, chapter: 9)
    var writer = try writerDisclosurePolicy(in: world, chapter: 9)
    #expect(try art.scrub("\(ending) \(endingQuestion)", .prose) == "[withheld]. [withheld]?")
    #expect(try writer.scrub("\(ending) \(endingQuestion)", .prose) == "\(ending) \(endingQuestion)")
  }

  @Test("should never let an unreadable unlock reveal, schedule or open a fact")
  func shouldLockUnreadableUnlock() {
    let scheduled = DisclosureFact(factKey: "scheduled", text: "The tide turns twice.", source: .manual, revealChapter: 2, unlock: .unreadable)
    let open = DisclosureFact(factKey: "open", text: "Salt burns the dead.", source: .manual, revealChapter: 1, unlock: .unreadable)
    let world = DisclosureWorld(facts: [scheduled, open], entities: [DisclosureEntity(entityKey: "mira", name: "Mira")])
    #expect(writerForbiddenFacts(in: world, chapter: 5).map(\.factKey) == ["open", "scheduled"])
    let view = knowledgeView(in: world, chapter: 5, contract: contract(pov: "mira", learns: ["scheduled"]))
    #expect(view.known.isEmpty && view.reveals.isEmpty)
    #expect(view.hidden.map(\.factKey) == ["scheduled", "open"])
  }

  @Test("should treat a source this version does not know as never seed")
  func shouldForbidUnknownSource() {
    let unknown = DisclosureFact(factKey: "unknown_source", text: "The well is a door.", source: nil)
    let seed = DisclosureFact(factKey: "seed_rule", text: "The dead never lie.", source: .seed)
    #expect(writerForbiddenFacts(in: DisclosureWorld(facts: [unknown, seed]), chapter: 3).map(\.factKey) == ["unknown_source"])
  }

  @Test("should take the later of two ending plans, so no chapter counts as at the ending that the other would hold back")
  func shouldTakeLaterEnding() {
    let world = DisclosureWorld(ending: ending, plans: [plan(3, isEnding: true), plan(7, isEnding: true)])
    #expect(writerDisclosureSources(in: world, chapter: 5).ending == ending)
    #expect(writerDisclosureSources(in: world, chapter: 7).ending == nil)
  }

  @Test("should ignore ledger rows whose fact or entity was removed, as the database deletes them with their parent")
  func shouldIgnoreOrphanedRows() {
    let fact = DisclosureFact(factKey: "heir", text: "Mara is the lost heir.", source: .manual, revealChapter: nil)
    let rows = [
      KnowledgeRow(factKey: "heir", entityKey: "removed", learnedInChapter: 1, source: .brief, status: .committed),
      KnowledgeRow(factKey: "removed_fact", entityKey: "mira", learnedInChapter: 1, source: .manual, status: .committed),
    ]
    let world = DisclosureWorld(facts: [fact], entities: [DisclosureEntity(entityKey: "mira", name: "Mira")], knowledge: rows)
    let view = knowledgeView(in: world, chapter: 4, contract: KnowledgeContract(pov: ["mira", "removed"], learns: []))
    #expect(view.known.isEmpty)
    #expect(view.learnedIn == [])
    #expect(view.pooledPov == [PovMember(entityKey: "mira", name: "Mira"), PovMember(entityKey: "removed", name: "removed")])
    #expect(writerForbiddenFacts(in: world, chapter: 4).map(\.factKey) == ["heir"])
  }

  @Test("should know a fact a POV member learned before the chapter and reveal one the plan may teach")
  func shouldPartitionByLedgerAndPlan() {
    let known = DisclosureFact(factKey: "known", text: "The bell is cracked.", source: .manual, revealChapter: 1, unlock: .condition(UnlockCondition(all: [.chapter(1)])))
    let taught = DisclosureFact(factKey: "taught", text: "The keeper is blind.", source: .manual, revealChapter: 3)
    let early = DisclosureFact(factKey: "early", text: "The lamp drinks memory.", source: .manual, revealChapter: 9)
    let world = DisclosureWorld(
      facts: [known, taught, early], entities: [DisclosureEntity(entityKey: "mira", name: "Mira")],
      knowledge: [KnowledgeRow(factKey: "known", entityKey: "mira", learnedInChapter: 2, source: .manual, status: .committed)],
      plans: [plan(4, contract: learns(pov: "mira", [("mira", "taught"), ("mira", "early")]))])
    let view = knowledgeView(in: world, chapter: 4, contract: contract(pov: "mira", learns: ["taught", "early"]))
    #expect(view.known.map(\.factKey) == ["known"])
    #expect(view.reveals.map(\.factKey) == ["taught"])
    #expect(view.hidden.map(\.factKey) == ["early"])
    #expect(view.learnedIn == [LearnedChapter(factKey: "known", chapter: 2)])
    #expect(writerForbiddenFacts(in: world, chapter: 4).map(\.factKey) == ["early"])
  }

  @Test("should never disclose open canon at the first chapter, with or without an unlock that holds there")
  func shouldNotDiscloseOpenCanon() {
    var world = DisclosureWorld(
      facts: [
        DisclosureFact(factKey: "open_rule", text: "Salt burns the dead.", source: .manual, revealChapter: 1),
        DisclosureFact(factKey: "open_gate", text: "The gate opens inward.", source: .manual, revealChapter: 1, unlock: .condition(UnlockCondition(all: [.chapter(1)]))),
        DisclosureFact(factKey: "dated", text: "The bell is cracked.", source: .manual, revealChapter: 2),
      ],
      plans: [plan(1), plan(2)])
    world.discloseChapterReveals(chapter: 1)
    #expect(world.facts.map(\.disclosedInChapter) == [nil, nil, nil])
    world.discloseChapterReveals(chapter: 2)
    #expect(world.facts.map(\.disclosedInChapter) == [nil, nil, 2])
  }

  @Test("should bring a plan's contract keys to NFC, so a decomposed key still names its fact")
  func shouldNormalisePlanContracts() {
    let decomposed = "cafe\u{301}"
    let contract = learns(pov: decomposed, [(decomposed, "f_\(decomposed)")])
    let ending = OrderedJSON.object(OrderedJSONObject([(key: "mustNotResolve", value: .array([.string("fact:f_\(decomposed)")]))]))
    let normalised = DisclosurePlan(
      normalizing: PlanClaims(chapter: 3, volumeKey: "v_\(decomposed)", isEnding: false, claimedMilestones: ["m_\(decomposed)"]), knowledgeContract: contract,
      endingContract: ending)
    let composed = "caf\u{e9}"
    #expect(normalised.claims.volumeKey?.jsEquals("v_\(composed)") == true)
    #expect(normalised.claims.claimedMilestones?.first?.jsEquals("m_\(composed)") == true)
    #expect(
      parseKnowledgeContract(normalised.row.knowledgeContract) == KnowledgeContract(pov: [composed], learns: [KnowledgeReveal(entityKey: composed, factKey: "f_\(composed)")]))
    #expect(mustNotResolveKeys(normalised.endingContract) == [JSString("f_\(composed)")])
    let fact = DisclosureFact(factKey: "f_\(composed)", text: "The cafe is a front.", source: .manual, revealChapter: 1)
    let world = DisclosureWorld(facts: [fact], plans: [normalised])
    #expect(writerForbiddenFacts(in: world, chapter: 3).map(\.factKey) == ["f_\(composed)"])
  }

  @Test("should read a secret record's malformed unlock as unreadable and a manual reveal as a committed row")
  func shouldBridgeRecords() {
    let novel = UUID()
    let malformed = SecretRecord(novel: novel, secret: "heir", text: "Mara is the heir.", unlock: .object(["any": .array([])]))
    let valid = SecretRecord(novel: novel, secret: "heir", text: "Mara is the heir.", unlock: .object(["all": .array([.object(["chapter": .int(3)])])]))
    let cleared = SecretRecord(novel: novel, secret: "heir", text: "Mara is the heir.", unlock: .null, source: .unknown("oracle"))
    #expect(DisclosureFact(secret: malformed, disclosedInChapter: nil).unlock == .unreadable)
    #expect(DisclosureFact(secret: valid, disclosedInChapter: 2).unlock == .condition(UnlockCondition(all: [.chapter(3)])))
    #expect(DisclosureFact(secret: cleared, disclosedInChapter: nil).unlock == nil)
    #expect(DisclosureFact(secret: cleared, disclosedInChapter: nil).source == nil)
    let reveal = CharacterKnowledgeRecord(novel: novel, fact: "heir", entity: "mira", reveal: ManualReveal(chapter: 4))
    #expect(KnowledgeRow(manual: reveal) == KnowledgeRow(factKey: "heir", entityKey: "mira", learnedInChapter: 4, source: .manual, status: .committed))
  }
}
