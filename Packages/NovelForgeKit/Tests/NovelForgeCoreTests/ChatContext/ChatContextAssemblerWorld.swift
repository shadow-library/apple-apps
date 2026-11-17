import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

struct ChatAssemblyFixture: Decodable {
  struct Spec: Decodable, Sendable {
    struct Novel: Decodable, Sendable {
      let title, premise, brief: String?
      let themes: [String]?
      let theme, endingQuestion, ending, readerPromise, protagonist, opposition, writingStyle: String?
    }

    struct Entry: Decodable, Sendable {
      let kind, topic, statement: String
      let why: String?
      let rejectedAlternatives: [String]
      let writerLine: String?
      let decidedBy: String
      let idea, scope, anchorVolume, anchorRef: String?
      let anchorChanged: Bool
      let progressStatus: String?
    }

    struct Volume: Decodable, Sendable {
      let key: String
      let ordinal: Int
      let title, objective: String?
      let goalMet, editedAfter: Bool
    }

    struct Thread: Decodable, Sendable {
      let key: String
      let summary: String?
      let openedChapter: Int?
      let status: String
      let payoffWindow: Int?
      let payoffMilestone, payoffVolume: String?
      let dormant: Bool
    }

    struct Mystery: Decodable, Sendable {
      let key, question: String
      let openedChapter: Int?
      let status: String
      let payoffWindow: Int?
      let payoffMilestone, payoffVolume: String?
      let dormant: Bool
    }

    struct Entity: Decodable, Sendable {
      let key, name, type: String
      let major: Bool
    }

    struct Page: Decodable, Sendable {
      let section, slug: String
      let title: String?
      let body: String
      let revisions: Int
      let editedAfter: Bool
    }

    struct Milestone: Decodable, Sendable {
      let key, label: String
    }

    struct Final: Decodable, Sendable {
      let chapter: Int
      let title, summary: String?
      let body: String
      let isolated: Bool
      let disclosed: [String]
      let viaDraft: Bool
    }

    struct Draft: Decodable, Sendable {
      let chapter: Int
      let title, summary: String?
      let body: String
      let isolated: Bool
    }

    struct Ending: Decodable, Sendable {
      let hookType, emotionalBeat, openQuestion, handoffState: String
    }

    struct Plan: Decodable, Sendable {
      let chapter: Int
      let title: String?
      let body: String
      let chapterPurpose, direction, pov: String?
      let scenes: [ChatPackScene]
      let ending: Ending?
      let contentMode: String?
      let isEnding: Bool
      let guidance: String?
      let writeMode: String
      let revisions: Int
      let editedAfter: Bool
    }

    let name: String
    let promptTokens, requestTokens: Int
    let novel: Novel?
    let notes: String?
    let ledger: [Entry]
    let volumes: [Volume]
    let threads: [Thread]
    let mysteries: [Mystery]
    let entities: [Entity]
    let pages: [Page]
    let secrets: [String]
    let milestones: [Milestone]
    let finals: [Final]
    let drafts: [Draft]
    let plans: [Plan]
    let pendingProposals: Int
  }

  struct Expected: Decodable {
    let sections: [ChatPackSection]
    let omitted: [ChatPackOmission]
    let usedTokens, budgetTokens: Int
    let renderedStable, renderedVolatile: String
  }

  struct Scenario: Decodable {
    let spec: Spec
    let expected: Expected
  }

  struct Update: Decodable {
    let scenario: Int
    let holding: String
    let text: String
    let sections: [[String]]
  }

  let scenarios: [Scenario]
  let updates: [Update]
  let historyAllowance: Int

  static let shared = Result { try ReferenceFixture.decode(ChatAssemblyFixture.self, from: "chat-assembly/chat-assembly.json") }
}

/// A scenario's vault, written through the typed records; what the spec marks as edited after is written once the session has opened.
enum ChatAssemblyWorld {
  static let novel = SchemaFixture.novel

  struct Built: Sendable {
    let store: VaultStore
    let session: UUID
    let since: HLCTimestamp
  }

  static func build(_ spec: ChatAssemblyFixture.Spec, allowingFaults: Bool = false) async throws -> Built {
    let store = try ReadWorld.store(allowingFaults: allowingFaults)
    try await ReadWorld.write(store) { transaction in try base(spec, in: &transaction) }
    try await ReadWorld.write(store) { transaction in try ledger(spec, in: &transaction) }
    for final in spec.finals.sorted(by: { $0.chapter < $1.chapter }) {
      if final.viaDraft {
        try await ReadWorld.write(store) { transaction in
          try draft(chapter: final.chapter, title: final.title, summary: final.summary, body: final.body, isolated: final.isolated, in: &transaction)
        }
      }
      try await ReadWorld.write(store) { transaction in try finalize(final, in: &transaction) }
    }
    for draft in spec.drafts {
      try await ReadWorld.write(store) { transaction in
        try Self.draft(chapter: draft.chapter, title: draft.title, summary: draft.summary, body: draft.body, isolated: draft.isolated, in: &transaction)
      }
    }
    let session = UUID()
    try await ReadWorld.write(store) { transaction in _ = try ChatSessionRecord(id: session, novel: novel).create(in: &transaction) }
    let since = try #require(try await store.read { transaction in try ChatContextLoader.sessionOpened(session, in: transaction) })
    try await ReadWorld.write(store) { transaction in try after(spec, in: &transaction) }
    return Built(store: store, session: session, since: since)
  }

  static func inputs(_ built: Built) async throws -> ChatContextInputs {
    try await built.store.read { transaction in try ChatContextLoader.load(novel: novel, since: built.since, in: transaction) }
  }

  private static func base(_ spec: ChatAssemblyFixture.Spec, in transaction: inout WriteTransaction) throws {
    if let story = spec.novel {
      _ = try NovelRecord(
        id: novel, name: "Novel", title: story.title, brief: story.brief, premise: story.premise, themes: story.themes, theme: story.theme,
        endingQuestion: story.endingQuestion, ending: story.ending, readerPromise: story.readerPromise, protagonist: story.protagonist, opposition: story.opposition,
        writingStyle: story.writingStyle
      ).create(in: &transaction)
    }
    if let notes = spec.notes { _ = try AuthorNotesRecord(novel: novel, content: AuthorNotesContent(text: notes)).create(in: &transaction) }
    for volume in spec.volumes {
      _ = try VolumeRecord(novel: novel, volume: volume.key, ordinal: volume.ordinal, title: volume.title, objective: volume.objective, goalMet: volume.goalMet)
        .create(in: &transaction)
    }
    for thread in spec.threads {
      _ = try ThreadRecord(
        novel: novel, thread: thread.key, summary: thread.summary, openedChapter: thread.openedChapter, status: ThreadProgress(state: StoredEnum(rawValue: thread.status)),
        payoffWindow: thread.payoffWindow, payoffMilestone: thread.payoffMilestone, payoffVolume: thread.payoffVolume, dormant: thread.dormant
      ).create(in: &transaction)
    }
    for mystery in spec.mysteries {
      _ = try MysteryRecord(
        novel: novel, mystery: mystery.key, question: mystery.question, openedChapter: mystery.openedChapter,
        status: MysteryProgress(state: StoredEnum(rawValue: mystery.status)), payoffWindow: mystery.payoffWindow, payoffMilestone: mystery.payoffMilestone,
        payoffVolume: mystery.payoffVolume, dormant: mystery.dormant
      ).create(in: &transaction)
    }
    let renamed = Set(spec.ledger.filter(\.anchorChanged).compactMap(\.anchorRef))
    for entity in spec.entities {
      let name = renamed.contains("entity:\(entity.key)") ? "\(entity.name) (earlier)" : entity.name
      _ = try EntityRecord(
        novel: novel, entity: entity.key, type: StoredEnum(rawValue: entity.type), name: name, significance: .known(entity.major ? .major : .minor)
      ).create(in: &transaction)
    }
    for page in spec.pages {
      let record = PageRecord(novel: novel, section: try #require(BiblePageSection(rawValue: page.section)), slug: page.slug, content: pageContent(page))
      _ = try record.create(in: &transaction)
      for _ in 1..<(page.editedAfter ? page.revisions - 1 : page.revisions) { _ = try PageRecord.revise(record.ref, body: record.content, in: &transaction) }
    }
    for secret in spec.secrets { _ = try SecretRecord(novel: novel, secret: secret, text: "The \(secret) is true.").create(in: &transaction) }
    for milestone in spec.milestones { _ = try MilestoneRecord(novel: novel, milestone: milestone.key, label: milestone.label).create(in: &transaction) }
    for plan in spec.plans {
      let record = try ChapterPlanRecord(novel: novel, chapter: plan.chapter, content: planContent(plan))
      _ = try record.create(in: &transaction)
      for _ in 1..<(plan.editedAfter ? plan.revisions - 1 : plan.revisions) { _ = try ChapterPlanRecord.revise(record.ref, record.content, in: &transaction) }
    }
    for _ in 0..<spec.pendingProposals { _ = try ProposalFixture.proposal(card: try ProposalFixture.card(novel: novel)).create(in: &transaction) }
    let settled = try ProposalFixture.proposal(card: try ProposalFixture.card(novel: novel))
    _ = try settled.create(in: &transaction)
    _ = try ProposalRecord.dismiss(settled.ref, as: .discarded, in: &transaction)
    _ = try ProposalFixture.proposal(card: try ProposalFixture.card(novel: SchemaFixture.otherNovel)).create(in: &transaction)
    _ = try EntityRecord(novel: SchemaFixture.otherNovel, entity: "stranger", type: .known(.character), name: "Stranger").create(in: &transaction)
  }

  /// Entries in their own write, after the records a rejection is anchored to; ids ascend so entries sharing a clock keep their order.
  private static func ledger(_ spec: ChatAssemblyFixture.Spec, in transaction: inout WriteTransaction) throws {
    for (index, entry) in spec.ledger.enumerated() {
      let id = SchemaFixture.uuid(String(format: "00000000-0000-4000-8000-%012x", index + 1))
      _ = try NotebookEntryRecord(
        id: id, novel: novel, entryKind: StoredEnum(rawValue: entry.kind), topic: entry.topic, statement: entry.statement, why: entry.why,
        rejectedAlternatives: entry.rejectedAlternatives, writerLine: entry.writerLine, decidedBy: StoredEnum(rawValue: entry.decidedBy),
        payload: entry.progressStatus.map { .object(["status": .string($0)]) }, idea: entry.idea, rejectionScope: entry.scope.map(StoredEnum.init(rawValue:)),
        rejectionAnchor: try anchor(entry, in: transaction)
      ).append(in: &transaction)
    }
  }

  private static func anchor(_ entry: ChatAssemblyFixture.Spec.Entry, in transaction: borrowing WriteTransaction) throws -> JSONValue? {
    if let volume = entry.anchorVolume { return .object(["volumeKey": .string(volume)]) }
    guard let ref = entry.anchorRef else { return nil }
    let states = try ArtifactStateLoader.states(refs: [ref], novel: novel, in: transaction)
    return RejectionAnchor.states([(ref: ref, state: try #require(states[JSString(ref)]))]).json.storable
  }

  private static func draft(chapter: Int, title: String?, summary: String?, body: String, isolated: Bool, in transaction: inout WriteTransaction) throws {
    let upstream = try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction)
    let content = DraftContent(title: title, body: body, summary: summary, source: .known(.generated), isolated: isolated, upstream: upstream)
    _ = try DraftRecord(novel: novel, chapter: chapter, content: content).create(in: &transaction)
  }

  private static func finalize(_ final: ChatAssemblyFixture.Spec.Final, in transaction: inout WriteTransaction) throws {
    let head = try ChapterWrites.head(novel: novel, chapter: final.chapter, in: transaction)
    let canon = Canon(
      draftRevision: head, title: final.title, body: final.body, summary: final.summary, isolated: final.isolated, contract: ChapterContract(), disclosed: final.disclosed)
    _ = try FinalChapterRecord(novel: novel, chapter: final.chapter, canon: canon).finalize(in: &transaction)
  }

  private static func after(_ spec: ChatAssemblyFixture.Spec, in transaction: inout WriteTransaction) throws {
    for volume in spec.volumes where volume.editedAfter {
      var edit = VolumeEdit()
      edit.title = .set(volume.title)
      _ = try VolumeRecord.edit(try volumeRef(volume.key), edit.fields, in: &transaction)
    }
    for plan in spec.plans where plan.editedAfter {
      _ = try ChapterPlanRecord.revise(try ChapterPlanRecord.ref(novel: novel, chapter: plan.chapter), planContent(plan), in: &transaction)
    }
    for page in spec.pages where page.editedAfter {
      let record = PageRecord(novel: novel, section: try #require(BiblePageSection(rawValue: page.section)), slug: page.slug, content: pageContent(page))
      _ = try PageRecord.revise(record.ref, body: record.content, in: &transaction)
    }
    for entity in spec.entities where spec.ledger.contains(where: { $0.anchorChanged && $0.anchorRef == "entity:\(entity.key)" }) {
      var edit = EntityEdit()
      edit.name = .set(entity.name)
      _ = try EntityRecord.edit(EntityRecord(novel: novel, entity: entity.key, type: .known(.character), name: "").ref, edit.fields, in: &transaction)
    }
  }

  private static func volumeRef(_ key: String) throws -> EntityRef { VolumeRecord(novel: novel, volume: key, ordinal: 0).ref }

  private static func pageContent(_ page: ChatAssemblyFixture.Spec.Page) -> PageContent {
    PageContent(frontmatter: page.title.map { ["title": .string($0)] }, body: page.body)
  }

  private static func planContent(_ plan: ChatAssemblyFixture.Spec.Plan) -> ChapterPlanContent {
    ChapterPlanContent(
      title: plan.title, body: plan.body, pov: plan.pov,
      endingContract: plan.ending.map {
        ChapterEndingContract(hookType: StoredEnum(rawValue: $0.hookType), emotionalBeat: $0.emotionalBeat, openQuestion: $0.openQuestion, handoffState: $0.handoffState)
      },
      contract: ChapterContract(isEnding: plan.isEnding), chapterPurpose: plan.chapterPurpose, guidance: plan.guidance, direction: plan.direction,
      contentMode: plan.contentMode.map(StoredEnum.init(rawValue:)), scenes: plan.scenes.map { PlanScene(BriefScene(summary: $0.summary, pov: $0.pov)) },
      writeMode: StoredEnum(rawValue: plan.writeMode))
  }
}
