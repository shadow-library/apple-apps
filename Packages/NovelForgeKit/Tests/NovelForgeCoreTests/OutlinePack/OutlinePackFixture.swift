import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

struct OutlinePackFixture: Decodable {
  struct Spec: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
      let kind, topic, statement: String
      let why: String?
      let rejectedAlternatives: [String]
      let writerLine: String?
      let decidedBy: String
      let progressStatus: String?
    }

    struct Volume: Decodable, Sendable {
      let key: String
      let ordinal: Int
      let title, objective: String?
      let goalMet: Bool
    }

    struct Promise: Decodable, Sendable {
      let key: String
      let summary, question: String?
      let openedChapter: Int?
      let status: String
      let payoffWindow: Int?
      let payoffMilestone, payoffVolume: String?
      let dormant: Bool
    }

    struct Entity: Decodable, Sendable {
      let key, name, type: String
      let major: Bool
      let body, notes, status: String?
    }

    struct Page: Decodable, Sendable {
      let section, slug: String
      let title: String?
      let body: String
    }

    struct Secret: Decodable, Sendable {
      let key, text: String
      let revealChapter: Int?
      let unlock: JSONValue?
      let source: String
      let terms: [String]
      let writerNote: String?
    }

    struct Milestone: Decodable, Sendable {
      let key, label: String
      let subject: String?
    }

    struct Final: Decodable, Sendable {
      let chapter: Int
      let title, summary: String?
      let body: String
      let isolated: Bool
      let disclosed, claims: [String]
      let state: [String: JSONValue]?
    }

    struct Draft: Decodable, Sendable {
      let chapter: Int
      let title, summary: String?
      let body: String
      let isolated: Bool
      let state: [String: JSONValue]?
    }

    struct Ending: Decodable, Sendable {
      let openQuestion, handoffState: String
    }

    struct Plan: Decodable, Sendable {
      let chapter: Int
      let title: String?
      let body: String
      let volume: String?
      let isEnding: Bool
      let claims: [String]
      let ending: Ending?
    }

    struct Knowledge: Decodable, Sendable {
      let fact, entity: String
      let chapter: Int
    }

    struct Volumed: Decodable, Sendable {
      let key: String?
    }

    struct Span: Decodable, Sendable {
      let start, end: Int
    }

    let name, mode: String
    let chapter: Int
    let budgetTokens: Int?
    let span: Span?
    let insertAfter: Int?
    let volume: Volumed?
    let ledger: [Entry]
    let volumes: [Volume]
    let threads: [Promise]
    let mysteries: [Promise]
    let entities: [Entity]
    let pages: [Page]
    let secrets: [Secret]
    let milestones: [Milestone]
    let finals: [Final]
    let drafts: [Draft]
    let plans: [Plan]
    let knowledge: [Knowledge]

    var request: OutlineRequest {
      OutlineRequest(
        chapter: chapter, budgetTokens: budgetTokens ?? OutlinePack.budget, span: span.map { ChapterSpan(start: $0.start, end: $0.end) }, insertAfter: insertAfter,
        volume: volume.map { .key($0.key) } ?? .nearest)
    }
  }

  struct Expected: Decodable {
    let sections: [ChatPackSection]?
    let omitted: [ChatPackOmission]?
    let usedTokens, budgetTokens: Int?
    let rendered, catalog, obligations, milestones, endingNote: String?
  }

  struct Scenario: Decodable {
    let spec: Spec
    let expected: Expected
  }

  let scenarios: [Scenario]
  let budget, timelineCap: Int

  static let shared = Result { try ReferenceFixture.decode(OutlinePackFixture.self, from: "outline-pack/outline-pack.json") }
}

enum OutlinePackWorld {
  static let novel = SchemaFixture.novel

  static func build(_ spec: OutlinePackFixture.Spec) async throws -> VaultStore {
    let store = try ReadWorld.store()
    try await ReadWorld.write(store) { transaction in try base(spec, in: &transaction) }
    try await ReadWorld.write(store) { transaction in try ledger(spec, in: &transaction) }
    for final in spec.finals.sorted(by: { $0.chapter < $1.chapter }) {
      try await ReadWorld.write(store) { transaction in
        try draft(chapter: final.chapter, title: final.title, summary: final.summary, body: final.body, isolated: final.isolated, state: final.state, in: &transaction)
      }
      try await ReadWorld.write(store) { transaction in try finalize(final, in: &transaction) }
    }
    for draft in spec.drafts {
      try await ReadWorld.write(store) { transaction in
        try Self.draft(chapter: draft.chapter, title: draft.title, summary: draft.summary, body: draft.body, isolated: draft.isolated, state: draft.state, in: &transaction)
      }
    }
    return store
  }

  private static func base(_ spec: OutlinePackFixture.Spec, in transaction: inout WriteTransaction) throws {
    for volume in spec.volumes {
      _ = try VolumeRecord(novel: novel, volume: volume.key, ordinal: volume.ordinal, title: volume.title, objective: volume.objective, goalMet: volume.goalMet).create(
        in: &transaction)
    }
    for thread in spec.threads {
      _ = try ThreadRecord(
        novel: novel, thread: thread.key, summary: thread.summary, openedChapter: thread.openedChapter, status: ThreadProgress(state: StoredEnum(rawValue: thread.status)),
        payoffWindow: thread.payoffWindow, payoffMilestone: thread.payoffMilestone, payoffVolume: thread.payoffVolume, dormant: thread.dormant
      ).create(in: &transaction)
    }
    for mystery in spec.mysteries {
      _ = try MysteryRecord(
        novel: novel, mystery: mystery.key, question: mystery.question ?? "", openedChapter: mystery.openedChapter,
        status: MysteryProgress(state: StoredEnum(rawValue: mystery.status)),
        payoffWindow: mystery.payoffWindow, payoffMilestone: mystery.payoffMilestone, payoffVolume: mystery.payoffVolume, dormant: mystery.dormant
      ).create(in: &transaction)
    }
    for entity in spec.entities {
      _ = try EntityRecord(
        novel: novel, entity: entity.key, type: StoredEnum(rawValue: entity.type), name: entity.name, significance: .known(entity.major ? .major : .minor), status: entity.status,
        notes: entity.notes, body: entity.body
      ).create(in: &transaction)
    }
    for page in spec.pages {
      let content = PageContent(frontmatter: page.title.map { ["title": .string($0)] }, body: page.body)
      _ = try PageRecord(novel: novel, section: try #require(BiblePageSection(rawValue: page.section)), slug: page.slug, content: content).create(in: &transaction)
    }
    for secret in spec.secrets {
      _ = try SecretRecord(
        novel: novel, secret: secret.key, text: secret.text, writerNote: secret.writerNote, cluesAndTerms: secret.terms.isEmpty ? nil : CluesAndTerms(terms: secret.terms),
        revealChapter: secret.revealChapter, unlock: secret.unlock, source: StoredEnum(rawValue: secret.source)
      ).create(in: &transaction)
    }
    for known in spec.knowledge {
      _ = try CharacterKnowledgeRecord(novel: novel, fact: known.fact, entity: known.entity, reveal: ManualReveal(chapter: known.chapter)).create(in: &transaction)
    }
    for milestone in spec.milestones {
      _ = try MilestoneRecord(novel: novel, milestone: milestone.key, label: milestone.label, subject: milestone.subject).create(in: &transaction)
    }
    for plan in spec.plans {
      let content = ChapterPlanContent(
        title: plan.title, body: plan.body, volume: plan.volume,
        endingContract: plan.ending.map { ChapterEndingContract(hookType: .known(.turn), emotionalBeat: "beat", openQuestion: $0.openQuestion, handoffState: $0.handoffState) },
        contract: ChapterContract(claimedMilestones: plan.claims, isEnding: plan.isEnding))
      _ = try ChapterPlanRecord(novel: novel, chapter: plan.chapter, content: content).create(in: &transaction)
    }
  }

  private static func ledger(_ spec: OutlinePackFixture.Spec, in transaction: inout WriteTransaction) throws {
    for (index, entry) in spec.ledger.enumerated() {
      let id = SchemaFixture.uuid(String(format: "00000000-0000-4000-8000-%012x", index + 1))
      _ = try NotebookEntryRecord(
        id: id, novel: novel, entryKind: StoredEnum(rawValue: entry.kind), topic: entry.topic, statement: entry.statement, why: entry.why,
        rejectedAlternatives: entry.rejectedAlternatives, writerLine: entry.writerLine, decidedBy: StoredEnum(rawValue: entry.decidedBy),
        payload: entry.progressStatus.map { .object(["status": .string($0)]) }
      ).append(in: &transaction)
    }
  }

  private static func draft(chapter: Int, title: String?, summary: String?, body: String, isolated: Bool, state: [String: JSONValue]?, in transaction: inout WriteTransaction)
    throws
  {
    let upstream = try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction)
    let content = DraftContent(title: title, body: body, summary: summary, source: .known(.generated), isolated: isolated, upstream: upstream, state: state)
    _ = try DraftRecord(novel: novel, chapter: chapter, content: content).create(in: &transaction)
  }

  private static func finalize(_ final: OutlinePackFixture.Spec.Final, in transaction: inout WriteTransaction) throws {
    let head = try ChapterWrites.head(novel: novel, chapter: final.chapter, in: transaction)
    let canon = Canon(
      draftRevision: head, title: final.title, body: final.body, summary: final.summary, isolated: final.isolated, contract: ChapterContract(claimedMilestones: final.claims),
      disclosed: final.disclosed)
    _ = try FinalChapterRecord(novel: novel, chapter: final.chapter, canon: canon).finalize(in: &transaction)
  }
}
