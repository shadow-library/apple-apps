import CryptoKit
import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

struct WriterPackFixture: Decodable {
  struct Spec: Decodable, Sendable {
    struct Novel: Decodable, Sendable {
      let writingStyle, ending, endingQuestion: String?
    }

    struct Volume: Decodable, Sendable {
      let key: String
      let ordinal: Int
      let title, objective, body: String?
      let goalMet: Bool
    }

    struct Secret: Decodable, Sendable {
      let key, text: String
      let constraintNote, writerNote: String?
      let terms, clues, subjects: [String]?
      let revealChapter: Int?
      let unlock: String?
      let source: String
    }

    struct Entity: Decodable, Sendable {
      let key, name, type: String
      let status, body, notes: String?
      let aliases: [String]
    }

    struct Knowledge: Decodable, Sendable {
      let fact, entity: String
      let chapter: Int
    }

    struct Thread: Decodable, Sendable {
      let key, status: String
      let openedChapter, closedChapter: Int?
      let summary: String?
    }

    struct Mystery: Decodable, Sendable {
      let key, status: String
      let openedChapter: Int?
      let question: String
    }

    struct Page: Decodable, Sendable {
      let section, slug, body: String
    }

    struct Entry: Decodable, Sendable {
      let kind, topic, statement: String
      let writerLine: String?
    }

    struct Learn: Decodable, Sendable {
      let entity, fact: String
    }

    struct Contract: Decodable, Sendable {
      let pov: [String]
      let learns: [Learn]
      let claimedMilestones: [String]
      let isEnding: Bool
    }

    struct Ending: Decodable, Sendable {
      let hookType, emotionalBeat, openQuestion, handoffState: String
      let mustNotResolve: [String]?
    }

    struct Plan: Decodable, Sendable {
      let chapter: Int
      let body: String
      let volume, pov: String?
      let contextRefs: [String]
      let chapterPurpose: String?
      let readerValue, repetitionRisks: [String]?
      let guidance: String?
      let ending: Ending?
      let contract: Contract
    }

    struct Final: Decodable, Sendable {
      let chapter: Int
      let title: String?
      let body: String
      let summary: String?
      let isolated: Bool
      let volume: String?
    }

    struct Draft: Decodable, Sendable {
      let chapter: Int
      let title: String?
      let body: String
      let summary: String?
      let isolated: Bool
      let state: String?
      let stale: Bool
    }

    struct CharacterState: Decodable, Sendable {
      let entity: String
      let location: String?
      let conditions: [String]?
      let immediateGoal, statusNote: String?
      let lastUpdatedChapter: Int
    }

    struct Relationship: Decodable, Sendable {
      let entity, target, kind: String
      let note: String?
      let chapter: Int?
    }

    struct WorldFact: Decodable, Sendable {
      let category, key, value: String
    }

    let name: String
    let chapter, budgetTokens: Int
    let permissive, enforce, storable: Bool
    let novel: Novel?
    let volumes: [Volume]
    let milestones: [String]
    let secrets: [Secret]
    let entities: [Entity]
    let knowledge: [Knowledge]
    let threads: [Thread]
    let mysteries: [Mystery]
    let pages: [Page]
    let ledger: [Entry]
    let plans: [Plan]
    let finals: [Final]
    let drafts: [Draft]
    let characterStates: [CharacterState]
    let relationships: [Relationship]
    let worldFacts: [WorldFact]

    var options: WriterPackOptions { WriterPackOptions(budgetTokens: budgetTokens, permissive: permissive, enforceReservations: enforce) }
  }

  struct Failure: Decodable, Sendable {
    let code, message: String
  }

  struct Expected: Decodable, Sendable {
    let budgetTokens, usedTokens: Int?
    let sections: [ChatPackSection]?
    let unresolvedRefs, withheldRefs: [String]?
    let omitted: [ChatPackOmission]?
    let renderedStable, renderedVolatile, rendered: String?
    let chapterBrief, endingContract: String
    let error: Failure?
  }

  struct Scenario: Decodable, Sendable {
    let spec: Spec
    let expected: Expected
  }

  struct Reservation: Decodable, Sendable {
    let name: String
    let tokens, cap: Int
    let fromPlan: Bool
  }

  struct Fit: Decodable, Sendable {
    let reservations: [Reservation]
    let budgetTokens: Int
    let error: Failure?
  }

  let scenarios: [Scenario]
  let fits: [Fit]
  let defaultBudget: Int

  static let shared = Result { try ReferenceFixture.decode(WriterPackFixture.self, from: "writer-pack/writer-pack.json") }
}

func writerPackDigest(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func writerPackFailureMessage(_ error: WriterPackError) -> String? {
  guard case .contextTooLarge = error else { return nil }
  return error.errorDescription
}

private let staleReason = StaleCause.unrecorded.reason

extension WriterPackFixture.Spec {
  var milestoneRows: [MilestoneRow] {
    let finals = Set(finals.map(\.chapter))
    return milestones.map { key in
      let reached = plans.filter { finals.contains($0.chapter) && $0.contract.claimedMilestones.contains(key) }.map(\.chapter)
      let planned = plans.contains { !finals.contains($0.chapter) && $0.contract.claimedMilestones.contains(key) }
      return MilestoneRow(milestoneKey: key, state: reached.isEmpty ? (planned ? .planned : .open) : .reached, reachedChapter: reached.min())
    }
  }

  func secretRecord(_ secret: Secret, novel: UUID) throws -> SecretRecord {
    let clues = secret.clues != nil || secret.terms != nil ? CluesAndTerms(clues: secret.clues, terms: secret.terms) : nil
    return SecretRecord(
      novel: novel, secret: secret.key, text: secret.text, subjects: secret.subjects, constraintNote: secret.constraintNote, writerNote: secret.writerNote,
      cluesAndTerms: clues, revealChapter: secret.revealChapter, unlock: try secret.unlock.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) },
      source: StoredEnum(rawValue: secret.source))
  }

  static func contract(_ contract: Contract) -> ChapterContract {
    ChapterContract(
      pov: contract.pov, learns: contract.learns.map { ContractLearn(KnowledgeReveal(entityKey: $0.entity, factKey: $0.fact)) },
      claimedMilestones: contract.claimedMilestones, isEnding: contract.isEnding)
  }

  static func ending(_ ending: Ending?) -> ChapterEndingContract? {
    ending.map {
      ChapterEndingContract(
        hookType: StoredEnum(rawValue: $0.hookType), emotionalBeat: $0.emotionalBeat, openQuestion: $0.openQuestion, handoffState: $0.handoffState,
        mustNotResolve: $0.mustNotResolve)
    }
  }

  /// The world as the reference's tables hold it, aliases, character states, relationships and world facts included.
  func world() throws -> WriterPackWorld {
    var world = WriterPackWorld(writingStyle: novel?.writingStyle, ending: novel?.ending, endingQuestion: novel?.endingQuestion)
    world.plans = plans.map { plan in
      let ending = Self.ending(plan.ending)
      return WriterPackPlan(
        chapter: plan.chapter, volume: plan.volume, pov: plan.pov, contextRefs: plan.contextRefs, contract: Self.contract(plan.contract), endingContract: ending,
        brief: WriterBriefInput(
          body: plan.body, pov: plan.pov, chapterPurpose: plan.chapterPurpose, readerValue: plan.readerValue ?? [], repetitionRisks: plan.repetitionRisks ?? [],
          guidance: plan.guidance, endingContract: ending))
    }
    world.finals = finals.map { WriterPackFinal(chapter: $0.chapter, title: $0.title, body: $0.body, summary: $0.summary, isolated: $0.isolated, volume: $0.volume) }
    world.drafts = try drafts.map { draft in
      WriterPackDraft(
        chapter: draft.chapter, body: draft.body, summary: draft.summary, state: try draft.state.map { try OrderedJSON(parsing: $0) }, isolated: draft.isolated,
        staleReason: draft.stale ? staleReason : nil)
    }
    world.volumes = volumes.map {
      WriterPackVolume(volume: $0.key, ordinal: $0.ordinal, title: $0.title, objective: $0.objective, body: $0.body, goalMet: $0.goalMet)
    }
    world.milestones = milestoneRows
    world.facts = try secrets.sorted { JSText.codeUnitPrecedes($0.key, $1.key) }.map {
      DisclosureFact(secret: try secretRecord($0, novel: SchemaFixture.novel), disclosedInChapter: nil)
    }
    world.knowledge = knowledge.map { KnowledgeRow(factKey: $0.fact, entityKey: $0.entity, learnedInChapter: $0.chapter, source: .manual, status: .committed) }
    world.entities = entities.sorted { JSText.codeUnitPrecedes($0.key, $1.key) }.map {
      WriterPackEntity(entity: $0.key, name: $0.name, type: $0.type, status: $0.status, body: $0.body, notes: $0.notes, aliases: $0.aliases)
    }
    world.characterStates = characterStates.map {
      WriterPackCharacterState(
        entity: $0.entity, location: $0.location, conditions: $0.conditions, immediateGoal: $0.immediateGoal, statusNote: $0.statusNote, lastUpdatedChapter: $0.lastUpdatedChapter)
    }
    world.relationships = relationships.enumerated().map {
      WriterPackRelationship(entity: $0.element.entity, target: $0.element.target, kind: $0.element.kind, note: $0.element.note, chapter: $0.element.chapter, order: $0.offset)
    }
    world.worldFacts = worldFacts.map { WriterPackWorldFact(category: $0.category, key: $0.key, value: $0.value) }
      .sorted { left, right in
        left.category.jsEquals(right.category) ? JSText.codeUnitPrecedes(left.key, right.key) : JSText.codeUnitPrecedes(left.category, right.category)
      }
    world.threads = threads.map { WriterPackThread(thread: $0.key, status: $0.status, openedChapter: $0.openedChapter, closedChapter: $0.closedChapter, summary: $0.summary) }
    world.mysteries = mysteries.map { WriterPackMystery(mystery: $0.key, status: $0.status, openedChapter: $0.openedChapter, question: $0.question) }
    world.pages = pages.map { DisclosurePage(address: BibleDocAddress(section: $0.section, slug: $0.slug), body: $0.body) }
    world.ledger = ledger.map { entry in
      ChatPackLedgerEntry(
        kind: LedgerEntryKind(rawValue: entry.kind) ?? .decision, topic: entry.topic, statement: entry.statement, why: nil, rejectedAlternatives: [], writerLine: entry.writerLine,
        decidedBy: .author, ideaId: nil, rejectionScope: nil)
    }
    return world
  }
}

/// A spec's novel written through the typed records, chapter by chapter so each draft records the chapters before it as they stand.
enum WriterPackVault {
  static let novel = SchemaFixture.novel

  static func build(_ spec: WriterPackFixture.Spec) async throws -> VaultStore {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in try base(spec, in: &transaction) }
    let finals = Dictionary(uniqueKeysWithValues: spec.finals.map { ($0.chapter, $0) })
    let drafts = Dictionary(uniqueKeysWithValues: spec.drafts.map { ($0.chapter, $0) })
    for chapter in Set(finals.keys).union(drafts.keys).sorted() {
      if let draft = drafts[chapter] { try await ReadWorld.write(store) { transaction in try write(draft, in: &transaction) } }
      if let final = finals[chapter] { try await ReadWorld.write(store) { transaction in try finalize(final, spec: spec, in: &transaction) } }
    }
    return store
  }

  static func load(_ store: VaultStore, chapter: Int) async throws -> WriterPackLoad {
    try await store.read { transaction in try WriterPackLoader.load(novel: novel, chapter: chapter, in: transaction) }
  }

  private static func base(_ spec: WriterPackFixture.Spec, in transaction: inout WriteTransaction) throws {
    if let story = spec.novel {
      _ = try NovelRecord(id: novel, name: "Novel", endingQuestion: story.endingQuestion, ending: story.ending, writingStyle: story.writingStyle).create(in: &transaction)
    }
    for volume in spec.volumes {
      _ = try VolumeRecord(novel: novel, volume: volume.key, ordinal: volume.ordinal, title: volume.title, objective: volume.objective, body: volume.body, goalMet: volume.goalMet)
        .create(in: &transaction)
    }
    for milestone in spec.milestones { _ = try MilestoneRecord(novel: novel, milestone: milestone, label: milestone).create(in: &transaction) }
    for secret in spec.secrets { _ = try spec.secretRecord(secret, novel: novel).create(in: &transaction) }
    for entity in spec.entities {
      _ = try EntityRecord(
        novel: novel, entity: entity.key, type: StoredEnum(rawValue: entity.type), name: entity.name, status: entity.status, notes: entity.notes, body: entity.body
      )
      .create(in: &transaction)
    }
    for item in spec.knowledge {
      _ = try CharacterKnowledgeRecord(novel: novel, fact: item.fact, entity: item.entity, reveal: ManualReveal(chapter: item.chapter)).create(in: &transaction)
    }
    for thread in spec.threads {
      _ = try ThreadRecord(
        novel: novel, thread: thread.key, summary: thread.summary, openedChapter: thread.openedChapter,
        status: ThreadProgress(state: StoredEnum(rawValue: thread.status), chapter: thread.closedChapter)
      ).create(in: &transaction)
    }
    for mystery in spec.mysteries {
      _ = try MysteryRecord(
        novel: novel, mystery: mystery.key, question: mystery.question, openedChapter: mystery.openedChapter, status: MysteryProgress(state: StoredEnum(rawValue: mystery.status))
      ).create(in: &transaction)
    }
    for page in spec.pages {
      _ = try PageRecord(novel: novel, section: try #require(BiblePageSection(rawValue: page.section)), slug: page.slug, content: PageContent(body: page.body)).create(
        in: &transaction)
    }
    for (index, entry) in spec.ledger.enumerated() {
      _ = try NotebookEntryRecord(
        id: SchemaFixture.uuid(String(format: "00000000-0000-4000-8000-%012x", index + 1)), novel: novel, entryKind: StoredEnum(rawValue: entry.kind), topic: entry.topic,
        statement: entry.statement, why: nil, rejectedAlternatives: [], writerLine: entry.writerLine, decidedBy: .known(.author), payload: nil, idea: nil, rejectionScope: nil,
        rejectionAnchor: nil
      ).append(in: &transaction)
    }
    for plan in spec.plans {
      let content = ChapterPlanContent(
        body: plan.body, volume: plan.volume, contextRefs: plan.contextRefs, pov: plan.pov, endingContract: WriterPackFixture.Spec.ending(plan.ending),
        contract: WriterPackFixture.Spec.contract(plan.contract), chapterPurpose: plan.chapterPurpose, readerValue: plan.readerValue, repetitionRisks: plan.repetitionRisks,
        guidance: plan.guidance)
      _ = try ChapterPlanRecord(novel: novel, chapter: plan.chapter, content: content).create(in: &transaction)
    }
  }

  private static func write(_ draft: WriterPackFixture.Spec.Draft, in transaction: inout WriteTransaction) throws {
    let upstream = draft.stale ? nil : try DraftUpstream.current(novel: novel, chapter: draft.chapter, in: transaction)
    let state = try draft.state.map { try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) }
    let content = DraftContent(
      title: draft.title, body: draft.body, summary: draft.summary, source: .known(.generated), isolated: draft.isolated, upstream: upstream, state: state)
    _ = try DraftRecord(novel: novel, chapter: draft.chapter, content: content).create(in: &transaction)
  }

  private static func finalize(_ final: WriterPackFixture.Spec.Final, spec: WriterPackFixture.Spec, in transaction: inout WriteTransaction) throws {
    let head = try ChapterWrites.head(novel: novel, chapter: final.chapter, in: transaction)
    let contract = spec.plans.first { $0.chapter == final.chapter }.map { WriterPackFixture.Spec.contract($0.contract) } ?? ChapterContract()
    let canon = Canon(
      draftRevision: head, title: final.title, body: final.body, summary: final.summary, isolated: final.isolated, volume: final.volume, contract: contract, disclosed: [])
    _ = try FinalChapterRecord(novel: novel, chapter: final.chapter, canon: canon).finalize(in: &transaction)
  }
}

func expectSamePack(_ pack: WriterPack, _ expected: WriterPackFixture.Expected, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
  let sections = expected.sections ?? []
  #expect(pack.sections.map(\.key) == sections.map(\.key), "\(name): section keys", sourceLocation: sourceLocation)
  for (section, wanted) in zip(pack.sections, sections) { expectSame(section, wanted, "\(name) \(wanted.key)", sourceLocation: sourceLocation) }
  #expect(pack.unresolvedRefs == expected.unresolvedRefs, "\(name): unresolved", sourceLocation: sourceLocation)
  #expect(pack.withheldRefs == expected.withheldRefs, "\(name): withheld", sourceLocation: sourceLocation)
  #expect(pack.omitted == expected.omitted, "\(name): omitted", sourceLocation: sourceLocation)
  #expect(pack.budgetTokens == expected.budgetTokens, "\(name): budget", sourceLocation: sourceLocation)
  #expect(pack.usedTokens == expected.usedTokens, "\(name): used", sourceLocation: sourceLocation)
  #expect(writerPackDigest(pack.renderedStable) == expected.renderedStable, "\(name): stable", sourceLocation: sourceLocation)
  #expect(writerPackDigest(pack.renderedVolatile) == expected.renderedVolatile, "\(name): volatile", sourceLocation: sourceLocation)
  #expect(writerPackDigest(pack.rendered) == expected.rendered, "\(name): rendered", sourceLocation: sourceLocation)
  expectSame(pack.brief.chapterBrief, expected.chapterBrief, "\(name): chapter brief", sourceLocation: sourceLocation)
  expectSame(pack.brief.endingContract, expected.endingContract, "\(name): ending contract", sourceLocation: sourceLocation)
}
