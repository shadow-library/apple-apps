import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Screen read models", TestTimeLimit.standard)
struct ScreenReadModelTests {
  @Test func shouldListEveryNotebookEntryWithItsSuccessorPredecessorAndWithdrawalReason() async throws {
    let store = try await ReadWorld.seeded()
    let (first, second) = try await store.write { transaction -> (UUID, UUID) in
      let first = try Notebook.record(NewNotebookEntry(kind: .decision, topic: "premise", statement: "A keeper", decidedBy: .author), novel: readNovel, in: &transaction)
      let second = try Notebook.record(NewNotebookEntry(kind: .direction, topic: "tone", statement: "Quiet", decidedBy: .author), novel: readNovel, in: &transaction)
      return (first.id, second.id)
    }
    let third = try await store.write { transaction in
      try Notebook.supersede(first, with: NotebookSuccessor(kind: .decision, decidedBy: .author, statement: "A lighthouse keeper"), novel: readNovel, in: &transaction).id
    }
    _ = try await store.write { transaction in try Notebook.withdraw(second, reason: "  too quiet  ", novel: readNovel, in: &transaction) }

    let history = try #require(try await store.load(NotebookHistory.self, readNovel).notebook.value)
    #expect(history.ledger.entries.map(\.id) == [first, second, third])
    #expect(history.ledger.entries.map(\.status) == [.superseded, .withdrawn, .active])
    #expect(history.counts == NotebookCounts(active: 1, superseded: 1, withdrawn: 1))
    let original = try #require(history.entry(first))
    let rewrite = try #require(history.entry(third))
    let withdrawn = try #require(history.entry(second))
    #expect(history.successor(of: original)?.id == third)
    #expect(history.predecessor(of: rewrite)?.id == first)
    #expect(history.predecessor(of: original) == nil)
    #expect(history.reason(for: withdrawn) == "too quiet")
    #expect(history.reason(for: rewrite) == nil)
    #expect(history.ledger.sections().decisions.map(\.id) == [third])
    #expect(history.ledger.history(topic: "premise").map(\.id) == [first, third])
  }

  @Test func shouldCountAnUnreadableEntryInTheNotebookHistory() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    _ = try await store.write { transaction in try transaction.append(NotebookEntryRecord.ref(UUID()), item: ["novel": .string(readNovel.uuidString.lowercased())]) }
    let history = try #require(try await store.load(NotebookHistory.self, readNovel).notebook.value)
    #expect(history.ledger.unreadable == 1)
    #expect(history.ledger.entries.isEmpty)
  }

  @Test func shouldLeaveTheNotebookHistoryUnavailableOnARecordIndexFault() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(IndexedRecord.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    #expect(try await store.load(NotebookHistory.self, readNovel).notebook.isUnavailable)
  }

  @Test func shouldReadTheNotesAsEmptyUntilWrittenAndObserveTheirChange() async throws {
    let store = try await ReadWorld.seeded()
    #expect(try await store.load(NovelNotes.self, readNovel).notes == .text(""))
    let (collected, task) = collect(store.observe(NovelNotes.self, readNovel))
    defer { task.cancel() }
    #expect(await collected.wait(for: 1))
    _ = try await store.write { transaction in try Library.replaceNotes(novel: readNovel, text: "  The bell rings twice.  ", in: &transaction) }
    #expect(await collected.wait(for: 2))
    #expect(await collected.values.map(\.notes) == [.text(""), .text("The bell rings twice.")])
  }

  @Test func shouldReportUnreadableNotes() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    _ = try await store.write { transaction in try Library.replaceNotes(novel: readNovel, text: "Readable.", in: &transaction) }
    _ = try await Projection.write(store) { transaction in try transaction.revise(AuthorNotesRecord.ref(novel: readNovel), body: .object(["text": .int(1)])) }
    #expect(try await store.load(NovelNotes.self, readNovel).notes == .unreadable)
  }

  @Test func shouldListRemovedRecordsUntilTheyAreRestored() async throws {
    let store = try await ReadWorld.seeded()
    _ = try await store.write { transaction in
      try Promises.create(novel: readNovel, .thread("debt"), label: "The debt", in: &transaction)
      _ = try Pages.save(novel: readNovel, section: .world, slug: "tides", body: "Salt water rises.", in: &transaction)
      _ = try Pages.save(novel: readOtherNovel, section: .world, slug: "tides", body: "Other.", in: &transaction)
      try Entities.create(novel: readNovel, entity: "alder", type: .character, name: "Alder", in: &transaction)
    }
    _ = try await store.write { transaction in
      try Volumes.remove(novel: readNovel, volume: "two", in: &transaction)
      try Milestones.remove(novel: readNovel, milestone: "fall", in: &transaction)
      try Promises.remove(novel: readNovel, .thread("debt"), in: &transaction)
      try Secrets.remove(novel: readNovel, secret: "heir", in: &transaction)
      try Pages.remove(novel: readNovel, section: .world, slug: "tides", in: &transaction)
      try Pages.remove(novel: readOtherNovel, section: .world, slug: "tides", in: &transaction)
      try Entities.remove(novel: readNovel, entity: "alder", in: &transaction)
    }
    let removed = try await store.load(RemovedRecords.self, readNovel)
    let story = try #require(removed.story.value)
    #expect(story.volumes.items.map(\.volume) == ["two"])
    #expect(story.milestones.items.map(\.milestone) == ["fall"])
    #expect(story.promises.items.map(\.key) == [JSString("debt")])
    guard case .thread(let thread)? = story.promises.items.first else {
      Issue.record("the removed promise should be the thread")
      return
    }
    #expect(thread.summary == "The debt")
    #expect(story.secrets.items.map(\.secret) == ["heir"])
    let bible = try #require(removed.bible.value)
    #expect(bible.pages.items.map(\.slug) == ["tides"])
    #expect(bible.pages.items.first?.excerpt == "Salt water rises.")
    #expect(bible.entities.items.map(\.entity) == ["alder"])

    _ = try await store.write { transaction in
      try Volumes.restore(novel: readNovel, volume: "two", in: &transaction)
      try Pages.restore(novel: readNovel, section: .world, slug: "tides", in: &transaction)
    }
    let after = try await store.load(RemovedRecords.self, readNovel)
    #expect(after.story.value?.volumes.items.isEmpty == true)
    #expect(after.bible.value?.pages.items.isEmpty == true)
    #expect(after.bible.value?.entities.items.map(\.entity) == ["alder"])
  }

  @Test func shouldLeaveRemovedRecordsUnavailableOnARecordIndexFault() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(IndexedRecord.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let removed = try await store.load(RemovedRecords.self, readNovel)
    #expect(removed.story.isUnavailable && removed.bible.isUnavailable)
  }

  @Test func shouldReportEachPlansVerdictAndTheViolationsOfOneSecret() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in
      try PlanWorldWrites.secret(novel: readNovel, "late", revealChapter: 4, in: &transaction)
      try PlanWorldWrites.putPlan(novel: readNovel, chapter: 3, planContent(volume: "one", contract(learns: [Learn("mara", "late")])), in: &transaction)
    }
    let report = try await store.load(PlanRevealReport.self, readNovel)
    let plans = try #require(report.plans.value)
    #expect(plans.map(\.chapter) == [1, 2, 3, 4])
    #expect(plans.map(\.status) == [.settled, .holds, .violated, .holds])
    #expect(report.violatedChapters == .available([3]))
    let late = try #require(report.violations(of: "late").value)
    #expect(late.map(\.chapter) == [3])
    #expect(late.first?.missing == plans[2].violations.first?.missing)
    #expect(late.first?.missing.isEmpty == false)
    #expect(report.violations(of: "heir") == .available([]))
  }

  @Test func shouldLeaveTheRevealReportUnavailableWhileThePlanWorldIs() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(PlanWorldEntry.databaseTableName, key: String(reflecting: readNovel), in: store)
    let report = try await store.load(PlanRevealReport.self, readNovel)
    #expect(report.plans.isUnavailable)
    #expect(report.violations(of: "heir").isUnavailable)
  }

  @Test func shouldLoadTheStoryScreenAsItsPartsInOneRead() async throws {
    let store = try await ReadWorld.seeded()
    _ = try await store.write { transaction in try Volumes.remove(novel: readNovel, volume: "two", in: &transaction) }
    let screen = try await store.load(StoryScreen.self, readNovel)
    #expect(screen.structure == (try await store.load(StoryStructure.self, readNovel)))
    #expect(screen.knowledge == (try await store.load(KnowledgeLedger.self, readNovel)))
    #expect(screen.reveals == (try await store.load(PlanRevealReport.self, readNovel)))
    #expect(screen.entities.value?.items.map(\.entity) == ["mara"])
    #expect(screen.entityName("mara") == "Mara")
    #expect(screen.entityName("nobody") == nil)
    #expect(screen.next == .available(2))
    #expect(screen.removed.value?.volumes.items.map(\.volume) == ["two"])
    #expect(screen.faults.isEmpty)
  }

  @Test func shouldKeepTheStoryCursorWhenTheRecordIndexIsFaulted() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(IndexedRecord.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let screen = try await store.load(StoryScreen.self, readNovel)
    #expect(screen.entities.isUnavailable && screen.removed.isUnavailable && screen.structure.secrets.isUnavailable)
    #expect(screen.next == .available(2))
    #expect(screen.faults.map(\.derivation) == [IndexedRecord.databaseTableName])
  }

  @Test func shouldFilePagesByTheStageOfTheRoleTheyCover() async throws {
    let store = try await ReadWorld.seeded()
    try await ReadWorld.write(store) { transaction in
      _ = try Pages.save(novel: readNovel, section: .world, slug: "territory", body: "Borders.", in: &transaction)
      _ = try Pages.save(novel: readNovel, section: .world, slug: "rivers", body: "Water.", in: &transaction)
    }
    let bible = try await store.load(StoryBibleContents.self, readNovel)
    let pages = try #require(bible.pages.value?.items)
    let stages = try #require(bible.stages.value)
    #expect(pages.map(\.slug) == ["rivers", "territory"])
    #expect(pages.map { stages.stage(of: $0) } == [nil, .factionsAndLocations])
    #expect(pages.map { BibleTopics.topic(of: $0, stages: stages) } == [.lore, .factions])
  }
}
