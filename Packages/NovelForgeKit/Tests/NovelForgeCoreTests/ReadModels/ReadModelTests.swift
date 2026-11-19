import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Read models", TestTimeLimit.standard)
struct ReadModelTests {
  @Test func shouldListTheLibraryWithChapterProgressAndTheArchiveApart() async throws {
    let store = try await ReadWorld.seeded()
    let library = try await store.load(LibraryList.self)
    #expect(library.novels.map(\.novel.name) == ["Ember"])
    #expect(library.archived.map(\.novel.name) == ["Alder"])
    #expect(library.novels[0].chapters == .available(ChapterTally(known: 4, finals: 1, drafted: 2, approved: 1, stale: 0, next: 2)))
    #expect(library.archived[0].chapters == .available(ChapterTally(known: 0, finals: 0, drafted: 0, approved: 0, stale: 0, next: 1)))
    #expect(library.unreadable == 0)
    #expect(library.faults.isEmpty)
  }

  @Test func shouldCountAnUnreadableNovelInTheLibrary() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await Projection.set(NovelForgeKey.novel(UUID()), ["archived": .bool(false)], in: store)
    #expect(try await store.load(LibraryList.self).unreadable == 1)
  }

  @Test func shouldSummariseANovelFromTheDerivedTables() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in
      _ = try Notebook.record(NewNotebookEntry(kind: .decision, topic: "premise", statement: "A keeper", decidedBy: .author), novel: readNovel, in: &transaction)
      _ = try Pages.save(novel: readNovel, section: .world, slug: "tides", body: "Salt.", in: &transaction)
    }
    let overview = try await store.load(NovelOverview.self, readNovel)
    guard case .present(let record) = overview.presence else {
      Issue.record("novel should be present")
      return
    }
    #expect(record.name == "Ember")
    #expect(overview.chapters == .available(ChapterTally(known: 4, finals: 1, drafted: 2, approved: 1, stale: 0, next: 2)))
    #expect(overview.activeVolume.value??.volume == "one")
    #expect(overview.milestones == .available(MilestoneTally(open: 1, planned: 1, reached: 0)))
    #expect(overview.notebookEntries == .available(1))
    #expect(overview.bible == .available(BibleTally(pages: 1, entities: 1)))
  }

  @Test func shouldReportAMissingNovel() async throws {
    let store = try await ReadWorld.seeded()
    let overview = try await store.load(NovelOverview.self, UUID())
    #expect(overview.presence == .missing)
    #expect(overview.chapters.value?.known == 0)
  }

  @Test func shouldShowStoryStructureWithDerivedStates() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: readNovel, chapter: 4, planContent(contract(claims: ["rise"])), in: &transaction)
      _ = try ThreadRecord(novel: readNovel, thread: "debt", summary: "The debt").create(in: &transaction)
      _ = try MysteryRecord(novel: readNovel, mystery: "light", question: "Who lit it?").create(in: &transaction)
    }
    let structure = try await store.load(StoryStructure.self, readNovel)
    let volumes = try #require(structure.volumes.value)
    #expect(volumes.items.map(\.record.volume) == ["one", "two"])
    #expect(volumes.items.map(\.state) == [.active, .notStarted])
    let milestones = try #require(structure.milestones.value)
    let rise = try #require(milestones.items.first { $0.record.milestone == "rise" })
    #expect(rise.state == .planned)
    #expect(rise.plannedChapter == 2)
    #expect(rise.duplicateClaims == [4])
    #expect(milestones.items.first { $0.record.milestone == "fall" }?.state == .open)
    #expect(structure.promises.value?.items.count == 2)
    #expect(structure.secrets.value?.items.map(\.secret) == ["heir"])
  }

  @Test func shouldCountUnreadableStoryRecords() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    let key = NovelForgeKey.volumeKey(novel: readNovel, volume: "bad")
    try await Projection.set(key.ref, ["natural_key": key.stored], in: store)
    let structure = try await store.load(StoryStructure.self, readNovel)
    #expect(structure.volumes.value?.unreadable == 1)
    #expect(structure.volumes.value?.items.count == 2)
  }

  @Test func shouldListTheStoryBibleBySectionAndKey() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in
      _ = try Pages.save(novel: readNovel, section: .world, slug: "tides", body: "Salt water rises.", in: &transaction)
      _ = try Pages.save(novel: readNovel, section: .world, slug: "ash", body: "Ash.", in: &transaction)
      _ = try Pages.save(novel: readOtherNovel, section: .world, slug: "other", body: "Other.", in: &transaction)
      try Entities.create(novel: readNovel, entity: "alder", type: .character, name: "Alder", in: &transaction)
    }
    let bible = try await store.load(StoryBibleContents.self, readNovel)
    #expect(bible.pages.value?.items.map(\.slug) == ["ash", "tides"])
    #expect(bible.pages.value?.items.last?.wordCount == 3)
    #expect(bible.entities.value?.items.map(\.entity) == ["alder", "mara"])
  }

  @Test func shouldShowTheActiveNotebookWithSectionsAndCounts() async throws {
    let store = try await ReadWorld.seeded()
    let ids = try await store.write { transaction -> [UUID] in
      let first = try Notebook.record(NewNotebookEntry(kind: .decision, topic: "premise", statement: "A keeper", decidedBy: .author), novel: readNovel, in: &transaction)
      let second = try Notebook.record(NewNotebookEntry(kind: .direction, topic: "tone", statement: "Quiet", decidedBy: .author), novel: readNovel, in: &transaction)
      return [first.id, second.id]
    }
    _ = try await store.write { transaction in try Notebook.withdraw(ids[1], reason: "no", novel: readNovel, in: &transaction) }
    let contents = try await store.load(NotebookContents.self, NotebookQuery(novel: readNovel))
    let notebook = try #require(contents.notebook.value)
    #expect(notebook.entries.map(\.id) == [ids[0]])
    #expect(notebook.sections.decisions.map(\.id) == [ids[0]])
    #expect(notebook.counts == NotebookCounts(active: 1, superseded: 0, withdrawn: 1))
    let filtered = try await store.load(NotebookContents.self, NotebookQuery(novel: readNovel, filter: NotebookFilter(kinds: [.direction])))
    #expect(filtered.notebook.value?.entries.isEmpty == true)
  }

  @Test func shouldCountAnUnreadableNotebookEntry() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    let ref = NotebookEntryRecord.ref(UUID())
    _ = try await store.write { transaction in try transaction.append(ref, item: ["novel": .string(readNovel.uuidString.lowercased())]) }
    let contents = try await store.load(NotebookContents.self, NotebookQuery(novel: readNovel))
    #expect(contents.notebook.value?.unreadable == 1)
  }

  @Test func shouldListChaptersWithTheirLifecycle() async throws {
    let store = try await ReadWorld.seeded()
    let list = try await store.load(ChapterList.self, readNovel)
    let rows = try #require(list.rows.value)
    #expect(rows.map(\.chapter) == [1, 2, 3, 4])
    #expect(rows.map(\.stage) == [.final, .approved, .drafted, .planned])
    #expect(rows[1].approval != nil)
    #expect(rows.allSatisfy { !$0.hasUnreadableCanon })
    #expect(list.next == .available(2))
    #expect(list.reveals.value?[1] == .settled)
  }

  @Test func shouldFlagAnUnreadableCanon() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    let key = try NovelForgeKey.finalChapterKey(novel: readNovel, chapter: 5)
    try await Projection.set(key.ref, ["natural_key": key.stored, "canon": .string("garbage")], in: store)
    let rows = try #require(try await store.load(ChapterList.self, readNovel).rows.value)
    #expect(rows.first { $0.chapter == 5 }?.hasUnreadableCanon == true)
    #expect(rows.first { $0.chapter == 5 }?.stage == .final)
  }

  @Test func shouldHeadChaptersFromCanonDraftOrPlan() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in
      var plan = planContent(volume: "one")
      plan.title = "Plan four"
      try PlanWorldWrites.putPlan(novel: readNovel, chapter: 4, plan, in: &transaction)
    }
    let headings = try #require(try await store.load(ChapterHeadings.self, readNovel).headings.value)
    #expect(headings.compactMapValues(\.title) == [4: "Plan four"])
    #expect(headings.compactMapValues(\.volume) == [1: "one", 2: "one", 3: "one", 4: "one"])
  }

  @Test func shouldLedgerCharacterKnowledgeInChapterOrder() async throws {
    let store = try await ReadWorld.seeded()
    let ledger = try await store.load(KnowledgeLedger.self, readNovel)
    let entries = try #require(ledger.entries.value)
    #expect(entries.map { "\($0.entity)/\($0.fact)@\($0.chapter) \($0.status.rawValue)" } == ["mara/heir@1 committed"])
    #expect(ledger.facts(known: "mara").value?.count == 1)
    #expect(ledger.knowers(of: "none").value?.isEmpty == true)
  }

  @Test func shouldLeaveAKnowledgeQueryUnavailableWhileTheLedgerIs() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(CharacterKnowledgeEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let ledger = try await store.load(KnowledgeLedger.self, readNovel)
    #expect(ledger.facts(known: "mara").isUnavailable)
    #expect(ledger.knowers(of: "heir").isUnavailable)
  }

  @Test func shouldHeadAFinalChapterFromItsAmendmentBoundToTheWinningCanonEvenWhenTheHeadIsAnotherCanons() async throws {
    let store = try await ReadWorld.seeded()
    let ref = try FinalChapterRecord.ref(novel: readNovel, chapter: 1)
    try await ReadWorld.write(store) { transaction in
      _ = try FinalChapterRecord.amend(ref, FinalChapterText(title: "Bound", body: "Bound text."), in: &transaction)
      _ = try transaction.revise(ref, body: FinalChapterAmendment(canon: "another canon", text: FinalChapterText(title: "Stray", body: "Stray.")).json)
    }
    let headings = try await store.load(ChapterHeadings.self, readNovel)
    #expect(headings.headings.value?[1]?.title == "Bound")
  }
}
