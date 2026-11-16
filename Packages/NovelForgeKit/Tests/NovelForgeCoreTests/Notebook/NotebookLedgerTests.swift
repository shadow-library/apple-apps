import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private typealias Fixture = NotebookFixture

@Suite("Notebook topics")
struct NotebookTopicTests {
  @Test func shouldMatchAnExactTopicOrEveryTopicUnderAWildcardPrefix() {
    #expect(NotebookTopics.matches("organise.rules", pattern: "organise.*"))
    #expect(NotebookTopics.matches("organise.a.b", pattern: "organise.*"))
    #expect(!NotebookTopics.matches("organise", pattern: "organise.*"))
    #expect(!NotebookTopics.matches("organised.rules", pattern: "organise.*"))
    #expect(NotebookTopics.matches("premise", pattern: "premise"))
    #expect(!NotebookTopics.matches("premise.x", pattern: "premise"))
    #expect(NotebookTopics.matches("anything", pattern: "*") == false)
    #expect(NotebookTopics.matches(".*", pattern: ".*"))
  }

  @Test func shouldHideTheBriefAndTheChecklistFromTheNotebookView() {
    #expect(!NotebookTopics.isVisibleInNotebook("start.brief"))
    #expect(!NotebookTopics.isVisibleInNotebook("progress.volume-1"))
    #expect(NotebookTopics.isVisibleInNotebook("idea.abc"))
    #expect(NotebookTopics.isVisibleInNotebook("start.briefs"))
  }

  @Test func shouldBuildTheTopicOfAnIdea() {
    #expect(NotebookTopics.idea("abc") == "idea.abc")
  }
}

@Suite("Notebook ledger")
struct NotebookLedgerTests {
  private func record(_ entries: [NewNotebookEntry], in store: VaultStore) async throws {
    _ = try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.record(entries, novel: Fixture.novel, in: &transaction) }.get()
  }

  private func filled() async throws -> VaultStore {
    let store = try await Fixture.store()
    var decided = Fixture.decision("premise")
    decided.rejectedAlternatives = ["A ghost story"]
    let entries = [
      decided,
      NewNotebookEntry(kind: .system, topic: "organise.rules", statement: "Rules", decidedBy: .system),
      NewNotebookEntry(kind: .direction, topic: "pace", statement: "Slow", decidedBy: .author),
      NewNotebookEntry(kind: .backlog, topic: "later", statement: "Sequel", decidedBy: .author),
      Fixture.rejection("i1"),
      NewNotebookEntry(kind: .direction, topic: "start.brief", statement: "Notes", decidedBy: .author),
      NewNotebookEntry(kind: .system, topic: "progress.volume-1", statement: "Done", decidedBy: .system),
    ]
    try await record(entries, in: store)
    return store
  }

  @Test func shouldListEntriesOldestFirst() async throws {
    let store = try await filled()
    #expect(try await Fixture.ledger(store).entries.map(\.record.topic) == ["premise", "organise.rules", "pace", "later", "idea.i1", "start.brief", "progress.volume-1"])
  }

  @Test func shouldFilterActiveEntriesByKindAndTopic() async throws {
    let ledger = try await Fixture.ledger(filled())
    #expect(ledger.active(matching: NotebookFilter(kinds: [.direction])).map(\.record.topic) == ["pace", "start.brief"])
    #expect(ledger.active(matching: NotebookFilter(topics: ["organise.*", "pace"])).map(\.record.topic) == ["organise.rules", "pace"])
    #expect(ledger.active(matching: NotebookFilter(kinds: [.system], topics: ["progress.*"])).map(\.record.topic) == ["progress.volume-1"])
    #expect(ledger.active().count == 7)
  }

  @Test func shouldHideTheBriefAndChecklistUnlessATopicFilterAsksForThem() async throws {
    let ledger = try await Fixture.ledger(filled())
    #expect(ledger.notebook().map(\.record.topic) == ["premise", "organise.rules", "pace", "later", "idea.i1"])
    #expect(ledger.notebook(matching: NotebookFilter(topics: ["start.brief"])).map(\.record.topic) == ["start.brief"])
  }

  @Test func shouldGroupTheActiveEntriesIntoTheReferenceSections() async throws {
    let sections = try await Fixture.ledger(filled()).sections()
    #expect(sections.decisions.map(\.record.topic) == ["premise", "organise.rules"])
    #expect(sections.directions.map(\.record.topic) == ["pace"])
    #expect(sections.backlog.map(\.record.topic) == ["later"])
    #expect(sections.rejected.map(\.record.topic) == ["idea.i1"])
    #expect(sections.passedOver == [NotebookSections.PassedOver(alternative: "A ghost story", topic: "premise")])
  }

  @Test func shouldLeaveRetiredEntriesOutOfTheActiveSetAndKeepThemInTheHistory() async throws {
    let store = try await filled()
    let ledger = try await Fixture.ledger(store)
    let pace = try #require(ledger.history(topic: "pace").first)
    _ = try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.withdraw(pace.id, reason: "Dropped", novel: Fixture.novel, in: &transaction) }.get()
    let premise = try #require(ledger.history(topic: "premise").first)
    let rewritten = try await Fixture.attempt(store) { transaction throws(NotebookError) in
      try Notebook.supersedeByAuthor(premise.id, rewrite: NotebookRewrite(statement: "Reworded"), novel: Fixture.novel, in: &transaction)
    }.get()

    let after = try await Fixture.ledger(store)
    #expect(after.active().map(\.record.topic) == ["organise.rules", "later", "idea.i1", "start.brief", "progress.volume-1", "premise"])
    #expect(after.history(topic: "premise").map(\.status) == [.superseded, .active])
    #expect(after.history(topic: "premise").map(\.id) == [premise.id, rewritten.id])
    #expect(after.history(topic: "pace").map(\.status) == [.withdrawn])
    #expect(after.sections().decisions.map(\.id).contains(premise.id) == false)
    #expect(after.sections().passedOver == [NotebookSections.PassedOver(alternative: "A ghost story", topic: "premise")])
  }

  @Test func shouldCountAnEntryItCannotReadWithoutListingIt() async throws {
    let store = try await filled()
    _ = try await store.write { transaction in try transaction.append(NovelForgeKey.notebookEntry(UUID()), item: ["novel": .string(Fixture.novel.uuidString.lowercased())]) }
    let ledger = try await Fixture.ledger(store)
    #expect(ledger.unreadable == 1)
    #expect(ledger.entries.count == 7)
  }
}
