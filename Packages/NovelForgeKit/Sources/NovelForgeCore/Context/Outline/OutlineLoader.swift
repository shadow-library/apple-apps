import Foundation
import GRDB
import ShadowCore
import ShadowStore

enum OutlineLoadError: ShadowError {
  case unreadable(parts: [String])
  case store(StoreError)
  case disclosure(DisclosureError)
  case hardLine(HardLineError)

  var code: String {
    switch self {
    case .unreadable: "outline.unreadable"
    case .store: "outline.store"
    case .disclosure: "outline.disclosure"
    case .hardLine(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .unreadable(let parts):
      "The story's \(parts.joined(separator: ", ")) cannot be read on this device just now, so the chapter cannot be planned from an incomplete picture of it."
    case .store(let error): error.localizedDescription
    case .disclosure(let error): error.localizedDescription
    case .hardLine(let error): error.errorDescription
    }
  }
}

struct OutlineLoad: Equatable, Sendable {
  let world: OutlineWorld
  let unreadable: [String]
}

private let chapterTables = [ChapterLifecycleEntry.databaseTableName, FinalChapterEntry.databaseTableName, IndexedRecord.databaseTableName]
private let planWorldTables = [PlanWorldEntry.databaseTableName, ChapterContractEntry.databaseTableName, IndexedRecord.databaseTableName]

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:587 and catalog.service.ts:182, every query read in one transaction
enum OutlineLoader {
  /// A part this version cannot read is reported rather than left out: a planner that cannot see a locked secret or a decision cannot plan around it.
  static func load(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> OutlineLoad {
    let faults = try FaultRows(in: transaction)
    let structure = try StoryStructure.load(novel, faults: faults, in: transaction)
    let knowledge = try KnowledgeLedger.load(novel, faults: faults, in: transaction)
    let report = ReadFaults(novel: novel, reading: chapterTables + planWorldTables, from: faults)
    var unreadable = [String]()
    func section<Item: Sendable & Equatable>(_ name: String, _ derived: Derived<StructureSection<Item>>) -> [Item] {
      guard let value = derived.value, value.unreadable == 0 else {
        unreadable.append(name)
        return derived.value?.items ?? []
      }
      return value.items
    }

    let volumeItems = section("volumes", structure.volumes)
    let milestoneItems = section("milestones", structure.milestones)
    let promiseItems = section("threads and mysteries", structure.promises)
    let secrets = section("secrets", structure.secrets)
    let knowers = knowledge.entries.value
    if knowers == nil { unreadable.append("knowledge ledger") }

    let entityListing = try StoryBibleContents.entities(of: novel, in: transaction)
    if entityListing.unreadable > 0 { unreadable.append("entities") }
    let pageListing = try PageRecord.indexedListing(novel: novel, in: transaction)
    if pageListing.unreadable > 0 { unreadable.append("Story Bible pages") }
    let notebook = try ChatContextLedger.notebook(novel: novel, volumes: volumeItems, in: transaction)
    if !notebook.complete { unreadable.append("notebook") }
    let planWorld = try storedPlanWorld(novel: novel, report: report, in: transaction)
    if planWorld == nil { unreadable.append("plan world") }

    let listed = try report.section(chapterTables) { () throws(StoreError) in try chapterListing(novel: novel, chapter: chapter, in: transaction) }
    if listed.isUnavailable { unreadable.append("chapters") }
    let chapters = listed.value ?? Chapters()
    let revealed = Set((knowers ?? []).map { JSString($0.fact) })
    let slot = try planSlot(novel: novel, chapter: chapter, in: transaction)
    var failedUnlock = [String]()
    let facts = secrets.map { secret -> OutlineFact in
      let unlock = secret.unlock.flatMap { UnlockCondition(validating: OrderedJSON($0)) }
      if secret.unlock != nil && unlock == nil { failedUnlock.append(secret.secret) }
      return OutlineFact(
        factKey: secret.secret, text: secret.text, revealChapter: secret.revealChapter, unlock: unlock, source: secret.source.known ?? .manual,
        terms: secret.cluesAndTerms?.terms ?? [], writerNote: secret.writerNote, revealed: revealed.contains(JSString(secret.secret)))
    }
    if !failedUnlock.isEmpty { unreadable.append("unlock conditions of \(failedUnlock.joined(separator: ", "))") }

    let world = OutlineWorld(
      chapters: chapters.finals, previous: chapters.previous, previousDraft: chapters.previousDraft,
      volumes: volumeItems.map { OutlineVolume(volumeKey: $0.record.volume, ordinal: $0.record.ordinal, title: $0.record.title, objective: $0.record.objective, state: $0.state) },
      entities: entityListing.items.map {
        OutlineEntity(entityKey: $0.entity, type: $0.type.rawValue, status: $0.status, body: $0.body, notes: $0.notes, isMajor: $0.significance == .known(.major))
      },
      threads: promiseItems.compactMap(thread), mysteries: promiseItems.compactMap(mystery), facts: facts,
      documents: pageListing.live.sorted { JSText.codeUnitPrecedes($0.slug, $1.slug) }.map {
        OutlineDocument(section: $0.section.rawValue, slug: $0.slug, frontmatter: $0.content.frontmatter, body: $0.content.body)
      },
      ledger: notebook.entries, planWorld: planWorld?.planWorld ?? NovelPlanWorld().planWorld,
      milestones: milestoneItems.map { OutlineMilestone(milestoneKey: $0.record.milestone, label: $0.record.label, subjectEntityKey: $0.record.subject, state: $0.state) },
      characters: entityListing.items.filter { $0.type == .known(.character) }.map(\.entity), slot: slot.slot, previousEnding: slot.previousEnding, neighbours: slot.neighbours,
      minorNames: minorNames(in: entityListing.items))
    return OutlineLoad(world: world, unreadable: unreadable)
  }

  /// The stored plan world, or nil while it or what it is built from is faulted, or when it is missing although the novel has records it is built from.
  // apps/novel-forge-server/src/common/plan-world.ts:39 (loadPlanState) as the plan-world derivation stored it
  private static func storedPlanWorld(novel: UUID, report: ReadFaults, in transaction: ReadTransaction) throws(StoreError) -> NovelPlanWorld? {
    guard report.blocking(planWorldTables).isEmpty else { return nil }
    let stored = try transaction.query { database in try PlanWorldEntry.filter(Column("novel") == novel).fetchOne(database) }
    guard let stored else {
      return try NovelPlanWorld.load(novel: novel, in: DerivationContext(records: transaction)) == nil ? NovelPlanWorld() : nil
    }
    return try? JSONDecoder().decode(NovelPlanWorld.self, from: stored.world)
  }

  private static func thread(_ promise: StoryPromise) -> OutlinePromise? {
    guard case .thread(let thread) = promise else { return nil }
    return OutlinePromise(
      kind: .thread, key: thread.thread, text: thread.summary, openedChapter: thread.openedChapter, isOpen: thread.status.state == .known(.open), intentionallyOpen: thread.dormant,
      lastAdvancedChapter: nil,
      payoff: PromisePayoff(payoffWindow: thread.payoffWindow, payoffMilestoneKey: thread.payoffMilestone, payoffVolumeKey: thread.payoffVolume))
  }

  private static func mystery(_ promise: StoryPromise) -> OutlinePromise? {
    guard case .mystery(let mystery) = promise else { return nil }
    return OutlinePromise(
      kind: .mystery, key: mystery.mystery, text: mystery.question, openedChapter: mystery.openedChapter, isOpen: mystery.status.state == .known(.open),
      intentionallyOpen: mystery.dormant, lastAdvancedChapter: nil,
      payoff: PromisePayoff(payoffWindow: mystery.payoffWindow, payoffMilestoneKey: mystery.payoffMilestone, payoffVolumeKey: mystery.payoffVolume))
  }

  private struct Chapters: Equatable, Sendable {
    var finals: [OutlineChapter] = []
    var previous: WriterEndingRow?
    var previousDraft: WriterEndingDraft?
  }

  /// A final chapter or draft this version cannot read reads as walled off, so it shows nothing of itself.
  private static func chapterListing(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> Chapters {
    let lifecycle = try transaction.query { database in try ChapterLifecycleEntry.filter(Column("novel") == novel).order(Column("chapter")).fetchAll(database) }
    var listing = Chapters()
    for entry in lifecycle {
      if entry.isFinal {
        let final = try finalText(novel: novel, chapter: entry.chapter, in: transaction)
        listing.finals.append(OutlineChapter(number: entry.chapter, title: final?.title, summary: final?.summary, isolated: final?.isolated ?? true))
        if entry.chapter == chapter - 1 {
          listing.previous = WriterEndingRow(finalized: true, isolated: final?.isolated ?? true, content: final?.body, summary: final?.summary)
        }
      }
      guard entry.chapter == chapter - 1, entry.draft != nil else { continue }
      let head = try draftHead(novel: novel, chapter: entry.chapter, in: transaction)
      listing.previousDraft = WriterEndingDraft(
        body: head?.body, summary: head?.summary, state: head?.state.map { OrderedJSON(.object($0)) }, isolated: head?.isolated ?? true,
        staleReason: entry.isFinal ? nil : entry.stale?.reason)
    }
    return listing
  }

  private struct FinalText {
    let title, summary, body: String?
    let isolated: Bool
  }

  private static func finalText(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> FinalText? {
    guard let ref = try? FinalChapterRecord.ref(novel: novel, chapter: chapter), case .readable(let entry) = try FinalChapterRecord.read(ref, in: transaction) else { return nil }
    let text = entry.record.text
    return FinalText(title: text.title, summary: text.summary, body: text.body, isolated: entry.record.canon.isolated)
  }

  private static func draftHead(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> DraftContent? {
    guard let ref = try? DraftRecord.ref(novel: novel, chapter: chapter), case .readable(let entry) = try DraftRecord.readHead(ref, in: transaction), !entry.isRemoved else {
      return nil
    }
    return try ChatTurnDrafts.readThrough(entry.record.content, novel: novel, chapter: chapter, in: transaction)
  }

  private struct Slot {
    var slot: OutlinePlanSlot?
    var previousEnding: PlanEnding?
    var neighbours: [OutlineNeighbour] = []
  }

  // apps/novel-forge-server/src/modules/actions/chapter-plan.service.ts:73,132: the chapter's own plan, the previous chapter's ending contract and the plans either side
  private static func planSlot(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> Slot {
    func head(_ number: Int) throws(StoreError) -> ChapterPlanContent? {
      guard let ref = try? ChapterPlanRecord.ref(novel: novel, chapter: number), case .readable(let entry) = try ChapterPlanRecord.readHead(ref, in: transaction), !entry.isRemoved
      else {
        return nil
      }
      return entry.record.content
    }
    var slot = Slot()
    if let existing = try head(chapter) { slot.slot = OutlinePlanSlot(volumeKey: existing.volume, isEnding: existing.contract.isEnding) }
    if let previous = try head(chapter - 1) {
      slot.previousEnding = previous.endingContract.map { PlanEnding(openQuestion: $0.openQuestion, handoffState: $0.handoffState) }
    }
    for number in [chapter - 1, chapter + 1] {
      if let neighbour = try head(number) { slot.neighbours.append(OutlineNeighbour(chapter: number, title: neighbour.title, body: neighbour.body)) }
    }
    return slot
  }
}
