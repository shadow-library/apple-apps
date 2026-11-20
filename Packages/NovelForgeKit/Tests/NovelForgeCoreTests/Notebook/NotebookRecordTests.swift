import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private typealias Fixture = NotebookFixture

@Suite("Notebook record")
struct NotebookRecordTests {
  private func record(_ entries: [NewNotebookEntry], novel: UUID = Fixture.novel, in store: VaultStore) async throws -> Result<[NotebookEntryRecord], NotebookError> {
    try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.record(entries, novel: novel, in: &transaction) }
  }

  @Test func shouldAppendAnEntryAndTrimTheTextTheWayTheReferenceDoes() async throws {
    let store = try await Fixture.store()
    var entry = Fixture.decision(statement: "  Keep the tide  ")
    entry.why = "   "
    entry.writerLine = " Show it "
    entry.rejectedAlternatives = ["a", "b"]
    entry.stepKey = "organise"
    entry.payload = .object(["k": .int(1)])
    entry.links = NotebookLinks(chapters: [2])
    let record = try await self.record([entry], in: store).get()[0]

    let ledger = try await Fixture.ledger(store)
    #expect(ledger.entries.map(\.record) == [record])
    #expect(record.statement == "Keep the tide")
    #expect(record.why == nil)
    #expect(record.writerLine == "Show it")
    #expect(record.rejectedAlternatives == ["a", "b"])
    #expect(record.decidedBy == .known(.author))
    #expect(record.supersedes == nil)
    #expect(record.links == NotebookLinks(chapters: [2]))
    #expect(ledger.entries[0].status == .active)
  }

  @Test func shouldAppendEveryKindTheReferenceKnows() async throws {
    let store = try await Fixture.store()
    let entries = LedgerEntryKind.allCases.map { NewNotebookEntry(kind: $0, topic: "t.\($0.rawValue)", statement: "s", decidedBy: $0 == .system ? .system : .author) }
    _ = try await record(entries, in: store).get()
    #expect(
      try await Fixture.ledger(store).entries.compactMap(\.record.entryKind.known).sorted { $0.rawValue < $1.rawValue }
        == LedgerEntryKind.allCases.sorted { $0.rawValue < $1.rawValue })
  }

  @Test func shouldWriteNothingForAnEmptyBatch() async throws {
    let store = try await Fixture.store()
    #expect(try await record([], in: store).get().isEmpty)
    #expect(try await Fixture.ledger(store).entries.isEmpty)
  }

  @Test(arguments: ["", "Upper", "-lead", "_lead", ".lead", "has space", "tab\t", "new\nline", "ünïcode", String(repeating: "a", count: 101), "trailing\n"])
  func shouldRefuseATopicThatIsNotAKey(topic: String) async throws {
    let store = try await Fixture.store()
    let failure = try await record([Fixture.decision(topic)], in: store).failure
    #expect(failure?.code == "LDG_004")
    #expect(failure?.errorDescription == "Ledger topic \"\(topic)\" is not a key of lowercase words joined by dots, dashes or underscores")
    #expect(try await Fixture.ledger(store).entries.isEmpty)
  }

  @Test(arguments: ["a", "0", "premise", "world.rules", "organise.rules", "a-b_c.d", String(repeating: "a", count: 100)])
  func shouldAcceptATopicThatIsAKey(topic: String) async throws {
    let store = try await Fixture.store()
    #expect(try await record([Fixture.decision(topic)], in: store).success?.count == 1)
  }

  @Test func shouldWriteNoneOfABatchWhenOneEntryIsRefused() async throws {
    let store = try await Fixture.store()
    #expect(try await record([Fixture.decision("good"), Fixture.decision("Bad")], in: store).failure?.code == "LDG_004")
    #expect(try await record([Fixture.decision("good"), Fixture.rejection("i1"), Fixture.rejection("i1")], in: store).failure?.code == "notebook.idea_already_rejected")
    #expect(try await Fixture.ledger(store).entries.isEmpty)
  }

  @Test func shouldRefuseAnEntryForAnUnknownNovel() async throws {
    let store = try await Fixture.store()
    #expect(try await record([Fixture.decision()], novel: Fixture.other, in: store).failure?.code == "PRJ_001")
    #expect(try await Fixture.ledger(store).entries.isEmpty)
  }

  @Test func shouldKeepEachNovelsEntriesApart() async throws {
    let store = try await Fixture.store()
    _ = try await store.write { transaction in try NovelRecord(id: Fixture.other, name: "Salt").create(in: &transaction) }
    _ = try await record([Fixture.decision("mine")], in: store).get()
    _ = try await record([Fixture.decision("theirs")], novel: Fixture.other, in: store).get()
    #expect(try await Fixture.ledger(store).entries.map(\.record.topic) == ["mine"])
    #expect(try await Fixture.ledger(store, novel: Fixture.other).entries.map(\.record.topic) == ["theirs"])
  }

  @Test func shouldStoreARejectionWithItsScopeAndAnchor() async throws {
    let store = try await Fixture.store()
    let anchor = JSONValue.object(["volumeKey": .string("one")])
    let written = try await record([Fixture.rejection("i1"), Fixture.rejection("i2", scope: .notNow, anchor: anchor)], in: store).get()
    #expect(written[0].rejectionScope == .known(.never))
    #expect(written[0].rejectionAnchor == nil)
    #expect(written[1].idea == "i2")
    #expect(written[1].rejectionScope == .known(.notNow))
    #expect(written[1].rejectionAnchor == anchor)
    #expect(written[1].topic == "idea.i2")
  }

  @Test func shouldRefuseARejectionWhoseScopeAndAnchorDisagree() async throws {
    let store = try await Fixture.store()
    let anchor = JSONValue.object(["volumeKey": .null])
    for entry in [Fixture.rejection("a", scope: .never, anchor: anchor), Fixture.rejection("b", scope: .notNow), Fixture.rejection("c", scope: .notThisVersion)] {
      #expect(try await record([entry], in: store).failure?.code == "notebook.invalid_rejection")
    }
    var notRejected = Fixture.rejection("d")
    notRejected.kind = .decision
    #expect(try await record([notRejected], in: store).failure?.code == "notebook.invalid_rejection")
    #expect(try await Fixture.ledger(store).entries.isEmpty)
  }

  @Test func shouldRefuseAnIdeaThatAlreadyHasAnActiveRejectionUntilItIsWithdrawn() async throws {
    let store = try await Fixture.store()
    let first = try await record([Fixture.rejection("i1")], in: store).get()[0]
    #expect(try await record([Fixture.rejection("i1", topic: "other")], in: store).failure?.code == "notebook.idea_already_rejected")
    _ = try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.withdraw(first.id, reason: "lifted", novel: Fixture.novel, in: &transaction) }.get()
    #expect(try await record([Fixture.rejection("i1", topic: "other")], in: store).success?.count == 1)
  }

  @Test func shouldRefuseAStepKeyOrIdeaIdThatIsTooLong() async throws {
    let store = try await Fixture.store()
    var long = Fixture.decision()
    long.stepKey = String(repeating: "s", count: 61)
    #expect(try await record([long], in: store).failure?.code == "notebook.too_long")
    #expect(try await record([Fixture.rejection(String(repeating: "i", count: 65))], in: store).failure?.code == "notebook.too_long")
    long.stepKey = String(repeating: "s", count: 60)
    #expect(try await record([long], in: store).success?.count == 1)
  }
}

@Suite("Notebook record by the author")
struct NotebookAuthorRecordTests {
  private func record(_ entry: AuthorNotebookEntry, in store: VaultStore) async throws -> Result<NotebookEntryRecord, NotebookError> {
    try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.recordByAuthor(entry, novel: Fixture.novel, in: &transaction) }
  }

  @Test(arguments: [LedgerEntryKind.direction, .rejected, .backlog])
  func shouldRecordADirectionARejectionOrABacklogItemAsTheAuthor(kind: LedgerEntryKind) async throws {
    let store = try await Fixture.store()
    let entry = AuthorNotebookEntry(kind: kind, topic: "pace", statement: "Slow", why: "Because", payload: ["a": .int(1)])
    let record = try await record(entry, in: store).get()
    #expect(record.entryKind == .known(kind))
    #expect(record.decidedBy == .known(.author))
    #expect(record.why == "Because")
    #expect(record.payload == .object(["a": .int(1)]))
    #expect(record.supersedes == nil)
  }

  @Test(arguments: [LedgerEntryKind.decision, .system])
  func shouldNotLetTheAuthorWriteADecisionFromNothing(kind: LedgerEntryKind) async throws {
    let store = try await Fixture.store()
    #expect(try await record(AuthorNotebookEntry(kind: kind, topic: "pace", statement: "Slow"), in: store).failure?.code == "notebook.kind_not_allowed")
  }

  @Test(arguments: ["start.brief", "progress.volume-1", "progress.", "idea.abc", "idea."])
  func shouldRefuseAReservedTopic(topic: String) async throws {
    let store = try await Fixture.store()
    let failure = try await record(AuthorNotebookEntry(kind: .direction, topic: topic, statement: "Slow"), in: store).failure
    #expect(failure?.code == "LDG_005")
    #expect(failure?.errorDescription == "Topic \"\(topic)\" is reserved for the server; the author cannot write to it directly")
  }

  @Test(arguments: ["start.briefs", "progressive", "ideas.x", "idea"])
  func shouldAllowATopicThatOnlyLooksReserved(topic: String) async throws {
    let store = try await Fixture.store()
    #expect(try await record(AuthorNotebookEntry(kind: .direction, topic: topic, statement: "Slow"), in: store).success != nil)
  }

  @Test func shouldApplyTheLimitsOfTheReferenceRoute() async throws {
    let store = try await Fixture.store()
    let base = AuthorNotebookEntry(kind: .direction, topic: "pace", statement: "Slow")
    var blank = base
    blank.statement = " \n "
    #expect(try await record(blank, in: store).failure?.code == "notebook.blank")
    blank.statement = ""
    #expect(try await record(blank, in: store).failure?.code == "notebook.blank")
    var long = base
    long.statement = String(repeating: "x", count: 4001)
    #expect(try await record(long, in: store).failure?.code == "notebook.too_long")
    long.statement = String(repeating: "x", count: 4000)
    #expect(try await record(long, in: store).success != nil)
    var why = base
    why.why = String(repeating: "x", count: 4001)
    #expect(try await record(why, in: store).failure?.code == "notebook.too_long")
    var malformed = base
    malformed.topic = "Pace"
    #expect(try await record(malformed, in: store).failure?.code == "LDG_004")
  }

  @Test func shouldMeasureLengthInUTF16UnitsLikeTheReference() async throws {
    let store = try await Fixture.store()
    let emoji = String(repeating: "😀", count: 2001)
    #expect(try await record(AuthorNotebookEntry(kind: .direction, topic: "pace", statement: emoji), in: store).failure?.code == "notebook.too_long")
  }
}
