import Foundation
import ShadowAI
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

enum ChatLookupWorlds {
  static func store(_ world: LookupWorld, allowingFaults: Bool = false) async throws -> VaultStore {
    let store = try ReadWorld.store(allowingFaults: allowingFaults)
    try await ReadWorld.write(store) { transaction in
      _ = try NovelRecord(id: readNovel, name: "Ember").create(in: &transaction)
      try writeStory(world, in: &transaction)
      try writeBible(world, in: &transaction)
      try writeUsage(world, in: &transaction)
    }
    try await ReadWorld.write(store) { transaction in try writeChapters(world, in: &transaction) }
    try await ReadWorld.write(store) { transaction in try finalize(world, in: &transaction) }
    return store
  }

  private static func versions<Content>(_ count: Int, _ final: Content, placeholder: (Int) -> Content) -> [Content] {
    (1..<max(count, 1)).map(placeholder) + [final]
  }

  private static func writeStory(_ world: LookupWorld, in transaction: inout WriteTransaction) throws {
    for volume in world.volumes {
      _ = try VolumeRecord(novel: readNovel, volume: volume.volumeKey, ordinal: volume.ordinal, title: volume.title, objective: volume.objective, body: volume.body).create(
        in: &transaction)
    }
    for thread in world.threads {
      let state = StoredEnum<ThreadStatus>(rawValue: thread.status)
      let progress = ThreadProgress(state: state, chapter: thread.closedChapter)
      _ = try ThreadRecord(
        novel: readNovel, thread: thread.threadKey, summary: thread.summary, openedChapter: thread.openedChapter, status: progress, payoffWindow: thread.payoffWindow,
        payoffMilestone: thread.payoffMilestoneKey, payoffVolume: thread.payoffVolumeKey, dormant: thread.intentionallyOpen
      ).create(in: &transaction)
    }
    for fact in world.facts {
      let terms = fact.terms == nil && fact.allowedClues == nil ? nil : CluesAndTerms(clues: fact.allowedClues, terms: fact.terms)
      let unlock = fact.unlock.flatMap { $0 == .null ? nil : $0 }
      _ = try SecretRecord(novel: readNovel, secret: fact.factKey, text: fact.text, writerNote: fact.writerNote, cluesAndTerms: terms, unlock: unlock).create(in: &transaction)
    }
    for entity in world.entities {
      _ = try EntityRecord(
        novel: readNovel, entity: entity.entityKey, type: StoredEnum<EntityType>(rawValue: entity.type), name: entity.name, status: entity.status, notes: entity.notes,
        body: entity.body?.value
      ).create(in: &transaction)
    }
    if let notes = world.notes { _ = try AuthorNotesRecord(novel: readNovel, content: AuthorNotesContent(text: notes)).create(in: &transaction) }
  }

  private static func writeBible(_ world: LookupWorld, in transaction: inout WriteTransaction) throws {
    for page in world.pages {
      guard let section = BiblePageSection(rawValue: page.section) else { continue }
      let content = PageContent(frontmatter: page.frontmatter, body: page.body?.value)
      let all = versions(page.revision, content) { PageContent(body: "version \($0)") }
      _ = try PageRecord(novel: readNovel, section: section, slug: page.slug, content: all[0]).create(in: &transaction)
      for next in all.dropFirst() { _ = try PageRecord.revise(novel: readNovel, section: section, slug: page.slug, next, in: &transaction) }
    }
  }

  private static func writeUsage(_ world: LookupWorld, in transaction: inout WriteTransaction) throws {
    for (index, call) in world.usage.enumerated() {
      let source: LedgerCostSource = call.source == "computed" ? .computed : .reported
      let entry = ModelCallEntry(
        id: UUID(), provider: "api.anthropic.com", model: call.model, task: ModelTask(rawValue: call.task) ?? .chat, pace: nil, startedMillis: 1_000 + Int64(index),
        outcome: .finished, usage: TokenUsage(input: call.input, output: call.output, cacheRead: call.cacheRead), cost: Cost(nanoUSD: call.nano), costSource: source)
      try Ledger.open(entry, in: &transaction)
    }
  }

  private static func writeChapters(_ world: LookupWorld, in transaction: inout WriteTransaction) throws {
    for brief in world.briefs {
      let learns = (brief.knowledgeContract?.learns ?? []).map { ContractLearn(KnowledgeReveal(entityKey: $0.entityKey, factKey: $0.factKey)) }
      let contract = ChapterContract(pov: brief.knowledgeContract?.pov ?? [], learns: learns)
      let ending = brief.endingContract.map {
        ChapterEndingContract(
          hookType: StoredEnum<HookType>(rawValue: $0.hookType), emotionalBeat: $0.emotionalBeat, openQuestion: $0.openQuestion, handoffState: $0.handoffState,
          mustNotResolve: $0.mustNotResolve)
      }
      let content = ChapterPlanContent(
        title: brief.title, body: brief.body.value, volume: brief.volumeKey, contextRefs: brief.contextRefs, pov: brief.pov, endingContract: ending, contract: contract,
        chapterPurpose: brief.chapterPurpose, readerValue: brief.readerValue, repetitionRisks: brief.repetitionRisks, guidance: brief.guidance,
        writeMode: StoredEnum<BriefWriteMode>(rawValue: brief.writeMode))
      let all = versions(brief.revision, content) { ChapterPlanContent(body: "version \($0)") }
      _ = try ChapterPlanRecord(novel: readNovel, chapter: brief.chapter, content: all[0]).create(in: &transaction)
      let ref = try ChapterPlanRecord.ref(novel: readNovel, chapter: brief.chapter)
      for next in all.dropFirst() { _ = try ChapterPlanRecord.revise(ref, next, in: &transaction) }
    }
    for draft in world.drafts {
      let upstream = try DraftUpstream.current(novel: readNovel, chapter: draft.chapter, in: transaction)
      let content = DraftContent(title: draft.title, body: draft.body.value, summary: draft.summary, source: .known(.generated), isolated: draft.isolated, upstream: upstream)
      let all = versions(draft.revision, content) { DraftContent(body: "version \($0)", source: .known(.generated), upstream: upstream) }
      _ = try DraftRecord(novel: readNovel, chapter: draft.chapter, content: all[0]).create(in: &transaction)
      let ref = try DraftRecord.ref(novel: readNovel, chapter: draft.chapter)
      for next in all.dropFirst() { _ = try DraftRecord.revise(ref, next, in: &transaction) }
    }
  }

  private static func finalize(_ world: LookupWorld, in transaction: inout WriteTransaction) throws {
    for draft in world.drafts where draft.reviewStatus == "approved" { try ChapterWrites.approve(novel: readNovel, chapter: draft.chapter, in: &transaction) }
    for chapter in world.chapters {
      let head = try ChapterWrites.head(novel: readNovel, chapter: chapter.number, in: transaction)
      let canon = Canon(
        draftRevision: head, title: chapter.title, body: "Final \(chapter.number).", summary: chapter.summary, isolated: chapter.isolated, contract: ChapterContract(),
        disclosed: chapter.disclosed)
      _ = try FinalChapterRecord(novel: readNovel, chapter: chapter.number, canon: canon).finalize(in: &transaction)
    }
  }
}
