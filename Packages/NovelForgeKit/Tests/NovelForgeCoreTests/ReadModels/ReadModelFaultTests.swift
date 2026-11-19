import Foundation
import GRDB
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Read model faults", TestTimeLimit.standard)
struct ReadModelFaultTests {
  @Test func shouldReportAWholeDerivationFaultAsUnavailableNotEmpty() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(ChapterLifecycleEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let list = try await store.load(ChapterList.self, readNovel)
    guard case .unavailable(let faults) = list.rows else {
      Issue.record("rows should be unavailable")
      return
    }
    #expect(faults.map(\.derivation) == [ChapterLifecycleEntry.databaseTableName])
    #expect(faults.first?.scope == .wholeDerivation)
    #expect(list.next.value == 2)
    #expect(list.reveals.value != nil)
    #expect(try await store.load(LibraryList.self).novels[0].chapters.isUnavailable)
    #expect(try await store.load(NovelOverview.self, readNovel).chapters.isUnavailable)
  }

  @Test func shouldReportAFaultOfThisNovelAndIgnoreAnotherNovelsFault() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(KnowledgeLedgerTables.knowledge, key: String(reflecting: readOtherNovel), in: store)
    #expect(try await store.load(KnowledgeLedger.self, readNovel).entries.value?.count == 1)
    try await ReadWorld.insertFault(KnowledgeLedgerTables.knowledge, key: String(reflecting: readNovel), in: store)
    let ledger = try await store.load(KnowledgeLedger.self, readNovel)
    #expect(ledger.entries.isUnavailable)
    #expect(ledger.faults.first?.scope == .novel)
  }

  @Test func shouldTreatAFaultOfAnUpstreamDerivationAsUnavailable() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(PlanWorldEntry.databaseTableName, key: String(reflecting: readNovel), in: store)
    #expect(try await store.load(KnowledgeLedger.self, readNovel).entries.isUnavailable)
    let list = try await store.load(ChapterList.self, readNovel)
    #expect(list.rows.isUnavailable)
    #expect(list.reveals.isUnavailable)
    #expect(list.next.value == 2)
  }

  @Test func shouldBlockTheRecordBackedSectionsOnARecordIndexFault() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(IndexedRecord.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let structure = try await store.load(StoryStructure.self, readNovel)
    #expect(structure.volumes.isUnavailable && structure.milestones.isUnavailable && structure.promises.isUnavailable && structure.secrets.isUnavailable)
    #expect(try await store.load(StoryBibleContents.self, readNovel).pages.isUnavailable)
    #expect(try await store.load(NotebookContents.self, NotebookQuery(novel: readNovel)).notebook.isUnavailable)
  }

  @Test func shouldListAnEntryFaultWithoutBlockingTheSection() async throws {
    let store = try await ReadWorld.seeded(allowingFaults: true)
    try await ReadWorld.insertFault(FinalChapterEntry.databaseTableName, key: "some entity", in: store)
    let list = try await store.load(ChapterList.self, readNovel)
    #expect(list.rows.value != nil)
    #expect(list.faults.map(\.scope) == [.entry])
  }
}

private enum KnowledgeLedgerTables {
  static let knowledge = CharacterKnowledgeEntry.databaseTableName
}
