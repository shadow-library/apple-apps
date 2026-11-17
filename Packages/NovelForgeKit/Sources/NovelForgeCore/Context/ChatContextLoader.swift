import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// A part of the vault the chat context reads; a part that cannot be read leaves out every section built from it.
enum ChatContextPart: String, CaseIterable, Sendable {
  case novel
  case notebook
  case notes
  case volumes
  case milestones
  case promises
  case secrets
  case bible
  case chapters
  case latestEnding
  case progress
  case proposals
}

struct ChatContextInputs: Equatable, Sendable {
  var pack: ChatPackInputs
  /// Parts that could not be read: their sections are left out.
  var unresolved: Set<ChatContextPart>
  /// Parts read without some of their records: their sections are kept and still reported.
  var incomplete: Set<ChatContextPart> = []
}

/// A head read with what the reference shows of it: its revision (`ChatLookupReader.revisionLabel`), and when it last changed.
private struct HeadRead<Record: Sendable & Equatable>: Sendable, Equatable {
  let record: Record
  let revision: String
  let changed: HLCTimestamp?
}

// apps/novel-forge-server/src/modules/ai/context/context-assembler.service.ts:753 (forNovelChat), every query read in one transaction
enum ChatContextLoader {
  private static let recordTables = [IndexedRecord.databaseTableName]
  private static let notebookTables = [NotebookEntryStateRow.databaseTableName]
  private static let chapterTables = [
    ChapterLifecycleEntry.databaseTableName, FinalChapterEntry.databaseTableName, StoryCursor.databaseTableName, IndexedRecord.databaseTableName,
  ]

  /// `since` is when the conversation opened (`sessionOpened`); nil leaves out what changed since.
  static func load(novel: UUID, since: HLCTimestamp?, in transaction: ReadTransaction) throws(StoreError) -> ChatContextInputs {
    let faults = try FaultRows(in: transaction)
    let report = ReadFaults(novel: novel, reading: recordTables + notebookTables + chapterTables, from: faults)
    let structure = try StoryStructure.load(novel, faults: faults, in: transaction)
    let disclosure = try ReaderDisclosure.load(novel, faults: faults, in: transaction)
    var unresolved = Set<ChatContextPart>()
    func part<Value>(_ part: ChatContextPart, _ derived: Derived<Value>, empty: Value) -> Value {
      guard let value = derived.value else {
        unresolved.insert(part)
        return empty
      }
      return value
    }

    let project = try readNovel(novel, in: transaction)
    if case .unreadable = project { unresolved.insert(.novel) }
    let notes = try NovelNotes.load(novel, in: transaction).notes
    if case .unreadable = notes { unresolved.insert(.notes) }
    let volumes = part(.volumes, structure.volumes, empty: StructureSection(items: [], unreadable: 0)).items
    let milestones = part(.milestones, structure.milestones, empty: StructureSection(items: [], unreadable: 0)).items
    let promises = part(.promises, structure.promises, empty: StructureSection(items: [], unreadable: 0)).items
    let secrets = part(.secrets, structure.secrets, empty: StructureSection(items: [], unreadable: 0)).items
    let notebook = part(
      .notebook,
      try report.section(notebookTables) { () throws(StoreError) in
        try ChatContextLedger.notebook(novel: novel, volumes: structure.volumes.value?.items, in: transaction)
      }, empty: ChatContextLedger.Notebook(entries: [], complete: true))
    var incomplete = Set<ChatContextPart>()
    if !notebook.complete { incomplete.insert(.notebook) }
    if disclosure.entries.isUnavailable { unresolved.insert(.secrets) }
    let bible = part(.bible, try report.section(recordTables) { () throws(StoreError) in try bibleListing(novel, in: transaction) }, empty: BibleListing())
    let chapters = part(.chapters, try report.section(chapterTables) { () throws(StoreError) in try chapterListing(novel, in: transaction) }, empty: ChapterListing())
    if chapters.latestUnreadable { unresolved.insert(.latestEnding) }
    let progress = try ProgressChecklist.load(novel, in: transaction).checklist.value
    if case .present = project, progress?.checklist == nil { unresolved.insert(.progress) }
    // context-assembler.service.ts:877 counts every pending proposal of the novel, a card this version cannot read included
    let proposals = try ChatPendingProposals.load(novel, in: transaction)
    if proposals.count.isUnavailable || !proposals.faults.isEmpty { incomplete.insert(.proposals) }

    let story: ChatPackStory?
    if case .present(let record) = project { story = Self.story(record) } else { story = nil }
    let inputs = ChatPackInputs(
      story: story,
      progress: story == nil ? nil : progress?.checklist.map { $0.items.map(Self.progressLine) },
      ledger: notebook.entries,
      authorNotes: notes.text,
      volumes: volumes.map { ChatPackVolume(volumeKey: $0.record.volume, ordinal: $0.record.ordinal, title: $0.record.title, objective: $0.record.objective, state: $0.state) },
      promises: promises.compactMap(Self.promise),
      entities: bible.entities.map { entity in
        ChatPackEntity(entityKey: entity.entity, name: entity.name, type: entity.type.rawValue, isMajor: entity.significance == .known(.major))
      },
      pages: bible.pages.map { ChatPackPage(section: $0.record.section.rawValue, slug: $0.record.slug, frontmatter: $0.record.content.frontmatter) },
      facts: secrets.map { ChatPackFact(factKey: $0.secret, in: disclosure) },
      milestones: milestones.map { ChatPackMilestone(milestoneKey: $0.record.milestone, label: $0.record.label, state: $0.state) },
      chapters: chapters.finals,
      drafts: chapters.drafts,
      plannedChapters: chapters.plans.map(\.record.chapter),
      briefs: chapters.briefs,
      latestChapter: chapters.latestChapter,
      latestDraft: chapters.latestDraft,
      pipeline: ChatPackPipeline(
        storyCurrentChapter: chapters.storyCurrentChapter, drafts: chapters.drafts.map { ChatPackPipeline.Draft(chapter: $0.chapter, review: $0.review) },
        staleBriefChapters: chapters.staleBriefChapters, pendingProposals: proposals.count.value ?? 0, awaiting: .none),
      changes: try since.map { since throws(StoreError) in try changes(since: since, volumes: volumes, plans: chapters.plans, pages: bible.pages, in: transaction) }
        ?? ChatPackChanges(volumes: [], briefs: [], docs: []))
    return ChatContextInputs(pack: inputs, unresolved: unresolved, incomplete: incomplete)
  }

  /// When the session was created, as its first-writer-wins `novel` member records it: the clock `load(since:)` takes for the reference's `session.createdAt`.
  static func sessionOpened(_ session: UUID, in transaction: ReadTransaction) throws(StoreError) -> HLCTimestamp? {
    guard case .record(let state)? = try transaction.state(of: ChatSessionRecord.ref(session), scope: .vault) else { return nil }
    return state[field: ChatSessionField.novel.rawValue]?.clock
  }

  private static func readNovel(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> NovelPresence {
    switch try NovelRecord.read(id: novel, in: transaction) {
    case .absent: .missing
    case .unreadable: .unreadable
    case .readable(let entry): entry.isRemoved ? .missing : .present(entry.record)
    }
  }

  // context-assembler.service.ts:812 and novel-chat-context.ts:41
  private static func story(_ novel: NovelRecord) -> ChatPackStory {
    ChatPackStory(
      title: novel.title, premise: novel.premise, brief: novel.brief, themes: novel.themes ?? [], theme: novel.theme, endingQuestion: novel.endingQuestion,
      ending: novel.ending, readerPromise: novel.readerPromise, protagonistKey: novel.protagonist, opposition: novel.opposition,
      authorInstructions: writingInstructionAdditions(novel.writingStyle))
  }

  private static func progressLine(_ item: ChecklistItem) -> ChatPackProgressLine {
    ChatPackProgressLine(status: ChatPackProgressStatus(rawValue: item.status.rawValue) ?? .dismissed, label: item.label)
  }

  /// `lastAdvancedChapter` has no v1 record (artifact-state.ts:215), so a promise reads as never moved since it opened; `dormant` is the reference's `intentionallyOpen`.
  // context-assembler.service.ts:758-759 reads the open threads and mysteries
  private static func promise(_ promise: StoryPromise) -> ChatPackPromise? {
    switch promise {
    case .thread(let thread):
      guard thread.status.state == .known(.open) else { return nil }
      return ChatPackPromise(
        kind: .thread, key: thread.thread, isOpen: true, text: thread.summary, openedChapter: thread.openedChapter, lastAdvancedChapter: nil,
        payoffWindow: thread.payoffWindow, payoffMilestoneKey: thread.payoffMilestone, payoffVolumeKey: thread.payoffVolume, intentionallyOpen: thread.dormant)
    case .mystery(let mystery):
      guard mystery.status.state == .known(.open) else { return nil }
      return ChatPackPromise(
        kind: .mystery, key: mystery.mystery, isOpen: true, text: mystery.question, openedChapter: mystery.openedChapter, lastAdvancedChapter: nil,
        payoffWindow: mystery.payoffWindow, payoffMilestoneKey: mystery.payoffMilestone, payoffVolumeKey: mystery.payoffVolume, intentionallyOpen: mystery.dormant)
    }
  }

  private struct BibleListing: Equatable, Sendable {
    var entities: [EntityRecord] = []
    var pages: [HeadRead<PageRecord>] = []
  }

  // context-assembler.service.ts:760-765: pages in section then slug order
  private static func bibleListing(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> BibleListing {
    let pages = try heads(PageRecord.self, novel: novel, in: transaction).sorted { left, right in
      let (first, second) = (left.record, right.record)
      guard first.section == second.section else { return JSText.codeUnitPrecedes(first.section.rawValue, second.section.rawValue) }
      return JSText.codeUnitPrecedes(first.slug, second.slug)
    }
    return BibleListing(entities: try StoryBibleContents.entities(of: novel, in: transaction).items, pages: pages)
  }

  private struct ChapterListing: Equatable, Sendable {
    var finals: [ChatPackChapter] = []
    var drafts: [ChatPackDraft] = []
    var plans: [HeadRead<ChapterPlanRecord>] = []
    var briefs: [ChatPackBrief] = []
    var latestChapter: ChatPackEndingRow?
    var latestDraft: ChatPackEndingDraft?
    var latestUnreadable = false
    var staleBriefChapters: [Int] = []
    var storyCurrentChapter = 0
  }

  /// A final chapter or draft this version cannot read counts as written and reads as walled off, so it moves the next chapter on and shows nothing of itself.
  private static func chapterListing(_ novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> ChapterListing {
    let lifecycle = try transaction.query { database in try ChapterLifecycleEntry.filter(Column("novel") == novel).order(Column("chapter")).fetchAll(database) }
    var listing = ChapterListing()
    var finalTexts = [Int: ChatPackEndingRow]()
    var draftBodies = [Int: ChatPackEndingDraft]()
    for entry in lifecycle {
      if entry.isFinal {
        let final = try finalChapter(novel: novel, chapter: entry.chapter, in: transaction)
        listing.finals.append(final?.chapter ?? ChatPackChapter(number: entry.chapter, title: nil, summary: nil, isolated: true))
        if let final { finalTexts[entry.chapter] = final.ending }
      }
      guard entry.draft != nil else { continue }
      let head = try draftHead(novel: novel, chapter: entry.chapter, in: transaction)
      let stale = entry.isFinal ? nil : entry.stale?.reason
      listing.drafts.append(
        ChatPackDraft(
          chapter: entry.chapter, title: head?.title, review: entry.review ?? .needsReview, summary: head?.summary, isolated: head?.isolated ?? true, staleReason: stale))
      if let head { draftBodies[entry.chapter] = ChatPackEndingDraft(body: head.body, summary: head.summary, isolated: head.isolated, staleReason: stale) }
    }
    listing.plans = try heads(ChapterPlanRecord.self, novel: novel, in: transaction).sorted { $0.record.chapter < $1.record.chapter }
    let planStale = Dictionary(lifecycle.compactMap { entry in entry.planStale.map { (entry.chapter, $0.reason) } }) { first, _ in first }
    listing.staleBriefChapters = listing.plans.map(\.record.chapter).filter { planStale[$0] != nil }
    let next = ChatPack.nextChapterNumber(chapters: listing.finals, drafts: listing.drafts)
    let latest = next - 1
    listing.briefs = listing.plans.filter { $0.record.chapter == latest || $0.record.chapter == next }.map { brief($0, staleReason: planStale[$0.record.chapter]) }
    if latest > 0 {
      listing.latestChapter = finalTexts[latest]
      listing.latestDraft = draftBodies[latest]
      let finalUnread = lifecycle.contains { $0.chapter == latest && $0.isFinal } && finalTexts[latest] == nil
      let draftUnread = lifecycle.contains { $0.chapter == latest && $0.draft != nil } && draftBodies[latest] == nil
      listing.latestUnreadable = finalUnread || (finalTexts[latest] == nil && draftUnread)
    }
    let cursor = try transaction.query { database in try StoryCursor.filter(Column("novel") == novel).fetchOne(database)?.chapter }
    listing.storyCurrentChapter = max((cursor ?? 1) - 1, 0)
    return listing
  }

  private struct FinalRead {
    let chapter: ChatPackChapter
    let ending: ChatPackEndingRow
  }

  private static func finalChapter(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> FinalRead? {
    guard let ref = try? FinalChapterRecord.ref(novel: novel, chapter: chapter), case .readable(let entry) = try FinalChapterRecord.read(ref, in: transaction) else {
      return nil
    }
    let text = entry.record.text
    let isolated = entry.record.canon.isolated
    return FinalRead(
      chapter: ChatPackChapter(number: chapter, title: text.title, summary: text.summary, isolated: isolated),
      ending: ChatPackEndingRow(content: text.body, summary: text.summary, isolated: isolated))
  }

  private static func draftHead(novel: UUID, chapter: Int, in transaction: ReadTransaction) throws(StoreError) -> DraftContent? {
    guard let ref = try? DraftRecord.ref(novel: novel, chapter: chapter), case .readable(let entry) = try DraftRecord.readHead(ref, in: transaction), !entry.isRemoved else {
      return nil
    }
    return entry.record.content
  }

  // novel-chat-context.ts:59
  private static func brief(_ plan: HeadRead<ChapterPlanRecord>, staleReason: String?) -> ChatPackBrief {
    let content = plan.record.content
    return ChatPackBrief(
      chapter: plan.record.chapter, title: content.title, chapterPurpose: content.chapterPurpose, direction: content.direction, body: content.body, pov: content.pov,
      scenes: (content.scenes ?? []).map { ChatPackScene(summary: $0.scene.summary, pov: $0.scene.pov) },
      endingContract: content.endingContract.map {
        ChatPackEndingContract(hookType: $0.hookType.rawValue, emotionalBeat: $0.emotionalBeat, openQuestion: $0.openQuestion, handoffState: $0.handoffState)
      },
      claimedMilestones: content.contract.claimedMilestones, contentMode: content.contentMode?.rawValue, isEnding: content.contract.isEnding, guidance: content.guidance,
      revision: plan.revision, staleReason: staleReason, writeMode: content.writeMode.known ?? .standard)
  }

  /// Volumes are field records with no revision counter, so a changed volume carries none.
  // context-assembler.service.ts:924 (changedSince): what changed after `since`, volumes then plans then pages
  private static func changes(
    since: HLCTimestamp, volumes: [VolumeItem], plans: [HeadRead<ChapterPlanRecord>], pages: [HeadRead<PageRecord>], in transaction: ReadTransaction
  ) throws(StoreError) -> ChatPackChanges {
    var changedVolumes = [ChatPackChanges.Volume]()
    for volume in volumes {
      guard let changed = try transaction.state(of: volume.record.ref, scope: .vault).flatMap(lastChange), changed > since else { continue }
      changedVolumes.append(ChatPackChanges.Volume(volumeKey: volume.record.volume, revision: nil))
    }
    return ChatPackChanges(
      volumes: changedVolumes,
      briefs: plans.filter { $0.changed.map { $0 > since } ?? false }.map { ChatPackChanges.Brief(chapter: $0.record.chapter, revision: $0.revision) },
      docs: pages.filter { $0.changed.map { $0 > since } ?? false }.map {
        ChatPackChanges.Doc(section: $0.record.section.rawValue, slug: $0.record.slug, revision: $0.revision)
      })
  }

  private static func heads<Record: HeadReadable>(_: Record.Type, novel: UUID, in transaction: ReadTransaction) throws(StoreError) -> [HeadRead<Record>] {
    let rows = try transaction.query { database in
      try IndexedRecord.filter(Column("novel") == novel && Column("kind") == Record.kind.rawValue && Column("status") != IndexedStatus.removed).fetchAll(database)
    }
    var found = [HeadRead<Record>]()
    for row in rows {
      let state = try transaction.stateNamingRevisions(of: row.ref, scope: .vault)
      guard case .readable(let entry) = Record.reading(state, of: row.ref), !entry.isRemoved else { continue }
      found.append(HeadRead(record: entry.record, revision: ChatLookupReader.revisionLabel(state), changed: state.flatMap(lastChange)))
    }
    return found
  }
}

/// When the record last changed: its newest member or head, as the reference's `updatedAt`.
func lastChange(_ state: EntityState) -> HLCTimestamp? {
  switch state {
  case .record(let record): record.fields.values.map(\.clock).max()
  case .revisioned(let revisioned): (Array(revisioned.fields.values) + [revisioned.head].compactMap(\.self)).map(\.clock).max()
  case .appended(let appended): appended.clock
  case .purged: nil
  }
}

extension NotesReading {
  fileprivate var text: String? {
    guard case .text(let text) = self else { return nil }
    return text
  }
}
