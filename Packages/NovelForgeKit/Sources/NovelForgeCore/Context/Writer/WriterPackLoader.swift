import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// A part of the vault the writer's disclosure policy is built from: one that cannot be read refuses the pack, as nothing could be scrubbed against it.
enum WriterPackPart: String, CaseIterable, Sendable {
  case novel
  case plans
  case chapters
  case volumes
  case milestones
  case secrets
  case pages
  case knowledge
}

struct WriterPackLoad: Equatable, Sendable {
  var world: WriterPackWorld
  var unreadable: [WriterPackPart]
  var minorNames: [String] = []
}

/// The vault as `forChapter` reads it, in one read. A final chapter's claims, volume and contract come from its canon, the rest of its plan from the plan head;
/// drafts are read at their committed head, as a pipeline pins them. The vault keeps no aliases, character states, relationships or world facts yet.
// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:196-222 and the loaders it calls
enum WriterPackLoader {
  private static let chapterTables = [ChapterLifecycleEntry.databaseTableName, FinalChapterEntry.databaseTableName, IndexedRecord.databaseTableName]
  private static let knowledgeTables = [CharacterKnowledgeEntry.databaseTableName]

  /// Only the drafts the pack of `chapter` reads are loaded: the previous chapter's and the recent-summary window's.
  static func load(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> WriterPackLoad {
    let faults = try FaultRows(in: transaction)
    let report = ReadFaults(novel: novel, reading: chapterTables + knowledgeTables, from: faults)
    let structure = try StoryStructure.load(novel, faults: faults, in: transaction)
    let disclosed = try ReaderDisclosure.load(novel, faults: faults, in: transaction)
    var unreadable = Set<WriterPackPart>()
    var world = WriterPackWorld()

    switch try NovelRecord.read(id: novel, in: transaction) {
    case .absent: break
    case .unreadable: unreadable.insert(.novel)
    case .readable(let entry):
      if !entry.isRemoved {
        world.writingStyle = entry.record.writingStyle
        world.ending = entry.record.ending
        world.endingQuestion = entry.record.endingQuestion
      }
    }

    if let volumes = structure.volumes.value, volumes.unreadable == 0 {
      world.volumes = volumes.items.map { item in
        let record = item.record
        return WriterPackVolume(
          volume: record.volume, ordinal: record.ordinal, title: record.title, objective: record.objective, body: record.body, goalMet: item.state == .goalMet)
      }
    } else {
      unreadable.insert(.volumes)
    }
    if let milestones = structure.milestones.value, milestones.unreadable == 0 {
      world.milestones = milestones.items.map { MilestoneRow(milestoneKey: $0.record.milestone, state: $0.state, reachedChapter: $0.reachedChapter) }
    } else {
      unreadable.insert(.milestones)
    }
    if let secrets = structure.secrets.value, secrets.unreadable == 0 {
      world.facts = secrets.items.map { DisclosureFact(secret: $0, disclosedInChapter: disclosed.chapter(of: $0.secret).value ?? nil) }
    } else {
      unreadable.insert(.secrets)
    }
    for promise in structure.promises.value?.items ?? [] {
      switch promise {
      case .thread(let thread):
        world.threads.append(
          WriterPackThread(
            thread: thread.thread, status: thread.status.state.rawValue, openedChapter: thread.openedChapter, closedChapter: thread.status.chapter, summary: thread.summary))
      case .mystery(let mystery):
        world.mysteries.append(
          WriterPackMystery(mystery: mystery.mystery, status: mystery.status.state.rawValue, openedChapter: mystery.openedChapter, question: mystery.question))
      }
    }

    let pages = try PageRecord.indexedListing(novel: novel, in: transaction)
    if pages.unreadable > 0 { unreadable.insert(.pages) }
    world.pages = pages.live.map { DisclosurePage(address: BibleDocAddress(section: $0.section.rawValue, slug: $0.slug), body: $0.content.body ?? "") }
    let entities = try StoryBibleContents.entities(of: novel, in: transaction).items
    world.entities = entities.map { entity in
      WriterPackEntity(entity: entity.entity, name: entity.name, type: entity.type.rawValue, status: entity.status, body: entity.body, notes: entity.notes)
    }
    world.ledger = try ChatContextLedger.notebook(novel: novel, volumes: nil, in: transaction).entries

    if let knowledge = try report.section(knowledgeTables, { () throws(StoreError) in try knowledgeRows(novel, in: transaction) }).value {
      world.knowledge = knowledge
    } else {
      unreadable.insert(.knowledge)
    }

    let plans = try ChapterPlanRecord.indexedListing(novel: novel, in: transaction)
    if plans.unreadable > 0 { unreadable.insert(.plans) }
    let heads = Dictionary(plans.live.map { ($0.chapter, $0.content) }) { first, _ in first }
    let window = (chapter - WriterPackRender.recentSummaryCount)...(chapter - 1)
    if let chapters = try report.section(chapterTables, { () throws(StoreError) in try chapters(novel, drafts: window, in: transaction) }).value {
      world.finals = chapters.finals.map(\.final)
      world.drafts = chapters.drafts
      if chapters.unreadableFinal { unreadable.insert(.chapters) }
      let canons = Dictionary(chapters.finals.map { ($0.final.chapter, $0.canon) }) { first, _ in first }
      world.plans = Set(heads.keys).union(canons.keys).sorted().map { chapter in plan(chapter: chapter, head: heads[chapter], canon: canons[chapter]) }
    } else {
      unreadable.insert(.chapters)
      world.plans = heads.keys.sorted().compactMap { chapter in heads[chapter].map { plan(chapter: chapter, head: $0, canon: nil) } }
    }
    return WriterPackLoad(world: world, unreadable: WriterPackPart.allCases.filter(unreadable.contains), minorNames: minorNames(in: entities))
  }

  private static func plan(chapter: Int, head: ChapterPlanContent?, canon: Canon?) -> WriterPackPlan {
    let brief = head.map { content in
      WriterBriefInput(
        body: content.body, pov: content.pov, chapterPurpose: content.chapterPurpose, readerValue: content.readerValue ?? [],
        repetitionRisks: content.repetitionRisks ?? [], guidance: content.guidance, endingContract: content.endingContract)
    }
    return WriterPackPlan(
      chapter: chapter, volume: canon.map(\.volume) ?? head?.volume, pov: head?.pov, contextRefs: head?.contextRefs ?? [],
      contract: canon?.contract ?? head?.contract ?? ChapterContract(), endingContract: head?.endingContract, brief: brief ?? WriterBriefInput())
  }

  private static func knowledgeRows(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [KnowledgeRow] {
    try transaction.query { database in try CharacterKnowledgeDerivation.request(for: novel).fetchAll(database) }.map { row in
      KnowledgeRow(factKey: row.fact, entityKey: row.entity, learnedInChapter: row.chapter, source: row.source, status: row.status)
    }
  }

  private struct FinalRead: Equatable {
    var final: WriterPackFinal
    var canon: Canon
  }

  private struct Chapters: Equatable {
    var finals: [FinalRead] = []
    var drafts: [WriterPackDraft] = []
    var unreadableFinal = false
  }

  private static func chapters(_ novel: UUID, drafts window: ClosedRange<Int>, in transaction: ReadTransaction) throws(StoreError) -> Chapters {
    let lifecycle = try transaction.query { database in try ChapterLifecycleEntry.filter(Column("novel") == novel).order(Column("chapter")).fetchAll(database) }
    var chapters = Chapters()
    for entry in lifecycle {
      if entry.isFinal {
        if let ref = try? FinalChapterRecord.ref(novel: novel, chapter: entry.chapter), case .readable(let read) = try FinalChapterRecord.read(ref, in: transaction) {
          let text = read.record.text
          let canon = read.record.canon
          chapters.finals.append(
            FinalRead(
              final: WriterPackFinal(chapter: entry.chapter, title: text.title, body: text.body, summary: text.summary, isolated: canon.isolated, volume: canon.volume),
              canon: canon))
        } else {
          chapters.unreadableFinal = true
        }
      }
      guard entry.draft != nil, window.contains(entry.chapter), let ref = try? DraftRecord.ref(novel: novel, chapter: entry.chapter),
        case .readable(let head) = try DraftRecord.readHead(ref, in: transaction), !head.isRemoved
      else { continue }
      let content = head.record.content
      // The vault returns state members in sorted key order; the reference's jsonb orders them shortest first, so neither keeps the writer's order.
      chapters.drafts.append(
        WriterPackDraft(
          chapter: entry.chapter, body: content.body, summary: content.summary, state: content.state.map { OrderedJSON(.object($0)) }, isolated: content.isolated,
          staleReason: entry.isFinal ? nil : entry.stale?.reason))
    }
    return chapters
  }
}

extension VaultStore {
  /// The writer pack of `chapter` from one read of the vault; `disclosure` is the policy the pack was scrubbed by, for whatever else the run shows the writer.
  func writerPack(
    novel: UUID, chapter: Int, options: WriterPackOptions = WriterPackOptions()
  ) async throws(WriterPackError) -> (pack: WriterPack, disclosure: WriterDisclosurePolicy) {
    let load: WriterPackLoad
    do {
      load = try await read { transaction in try WriterPackLoader.load(novel: novel, chapter: chapter, in: transaction) }
    } catch {
      throw .store(error)
    }
    guard load.unreadable.isEmpty else { throw .unreadable(load.unreadable) }
    var options = options
    options.minorNames = (options.minorNames + load.minorNames).jsUnique()
    return try WriterPackAssembler.assemble(load.world, chapter: chapter, options: options)
  }
}
