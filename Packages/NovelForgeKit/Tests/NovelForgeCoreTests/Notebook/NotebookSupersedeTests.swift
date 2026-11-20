import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private typealias Fixture = NotebookFixture

private func supersede(_ id: UUID, with next: NotebookSuccessor, in store: VaultStore) async throws -> Result<NotebookEntryRecord, NotebookError> {
  try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.supersede(id, with: next, novel: Fixture.novel, in: &transaction) }
}

private func rewrite(_ id: UUID, _ rewrite: NotebookRewrite, in store: VaultStore) async throws -> Result<NotebookEntryRecord, NotebookError> {
  try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.supersedeByAuthor(id, rewrite: rewrite, novel: Fixture.novel, in: &transaction) }
}

private func withdraw(_ id: UUID, _ reason: String = "No longer true", novel: UUID = Fixture.novel, in store: VaultStore) async throws -> Result<
  NotebookWithdrawalRecord, NotebookError
> {
  try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.withdraw(id, reason: reason, novel: novel, in: &transaction) }
}

private func seed(_ entry: NewNotebookEntry, in store: VaultStore) async throws -> NotebookEntryRecord {
  try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.record(entry, novel: Fixture.novel, in: &transaction) }.get()
}

@Suite("Notebook supersede")
struct NotebookSupersedeTests {
  private let successor = NotebookSuccessor(kind: .decision, decidedBy: .author, statement: "  A lighthouse keeper's daughter  ", why: "Closer")

  @Test func shouldWriteASuccessorOnTheSameTopicThatNamesTheEntryItReplaces() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision("premise"), in: store)
    let next = try await supersede(old.id, with: successor, in: store).get()

    #expect(next.topic == "premise")
    #expect(next.supersedes == old.id)
    #expect(next.statement == "A lighthouse keeper's daughter")
    #expect(next.why == "Closer")
    let ledger = try await Fixture.ledger(store)
    #expect(ledger.active().map(\.id) == [next.id])
    #expect(ledger.entry(old.id)?.state.successor == next.id)
    #expect(ledger.entry(old.id)?.status == .superseded)
    #expect(ledger.history(topic: "premise").map(\.id) == [old.id, next.id])
  }

  @Test func shouldRefuseAnEntryThatDoesNotExistOrBelongsToAnotherNovel() async throws {
    let store = try await Fixture.store()
    _ = try await store.write { transaction in try NovelRecord(id: Fixture.other, name: "Salt").create(in: &transaction) }
    let foreign = try await Fixture.attempt(store) { transaction throws(NotebookError) in try Notebook.record(Fixture.decision(), novel: Fixture.other, in: &transaction) }.get()
    #expect(try await supersede(UUID(), with: successor, in: store).failure?.code == "LDG_001")
    #expect(try await supersede(foreign.id, with: successor, in: store).failure?.code == "LDG_001")
    #expect(try await Fixture.ledger(store, novel: Fixture.other).active().map(\.id) == [foreign.id])
  }

  @Test func shouldRefuseAnEntryThatIsAlreadySupersededOrWithdrawn() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision("a"), in: store)
    let dropped = try await seed(Fixture.decision("b"), in: store)
    _ = try await supersede(old.id, with: successor, in: store).get()
    _ = try await withdraw(dropped.id, in: store).get()
    for id in [old.id, dropped.id] {
      let failure = try await supersede(id, with: successor, in: store).failure
      #expect(failure?.code == "LDG_002")
      #expect(failure?.errorDescription == "Ledger entry is already superseded or withdrawn — change the active entry on its topic instead")
    }
    #expect(try await Fixture.ledger(store).entries.count == 3)
  }

  @Test func shouldLetARejectionBeSupersededByTheSameIdea() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.rejection("i1", scope: .notNow, anchor: .object(["volumeKey": .string("one")])), in: store)
    var next = successor
    next.kind = .rejected
    next.idea = NotebookIdeaRejection(ideaId: "i1", scope: .never)
    let written = try await supersede(old.id, with: next, in: store).get()
    #expect(written.topic == "idea.i1")
    #expect(written.rejectionScope == .known(.never))
    #expect(try await Fixture.ledger(store).active().map(\.id) == [written.id])
  }

  @Test func shouldRefuseASuccessorWhoseIdeaBelongsToAnotherActiveRejection() async throws {
    let store = try await Fixture.store()
    _ = try await seed(Fixture.rejection("i1"), in: store)
    let other = try await seed(Fixture.rejection("i2"), in: store)
    var next = successor
    next.kind = .rejected
    next.idea = NotebookIdeaRejection(ideaId: "i1", scope: .never)
    #expect(try await supersede(other.id, with: next, in: store).failure?.code == "notebook.idea_already_rejected")
  }
}

@Suite("Notebook supersede by the author")
struct NotebookAuthorSupersedeTests {
  @Test func shouldKeepTheOmittedFieldsOfAnEntryWhoseKindIsKept() async throws {
    let store = try await Fixture.store()
    var entry = Fixture.decision("premise")
    entry.why = "Because"
    entry.writerLine = "Line"
    entry.rejectedAlternatives = ["x"]
    entry.payload = .object(["k": .int(1)])
    entry.links = NotebookLinks(entities: ["e"])
    entry.stepKey = "organise"
    let old = try await seed(entry, in: store)
    let next = try await rewrite(old.id, NotebookRewrite(statement: "New"), in: store).get()

    #expect(next.entryKind == .known(.decision))
    #expect(next.decidedBy == .known(.author))
    #expect(next.why == "Because")
    #expect(next.writerLine == "Line")
    #expect(next.rejectedAlternatives == ["x"])
    #expect(next.payload == .object(["k": .int(1)]))
    #expect(next.links == NotebookLinks(entities: ["e"]))
    #expect(next.stepKey == "organise")
    #expect(next.supersedes == old.id)
  }

  @Test func shouldClearATextFieldWithAnEmptyStringAndReplaceAList() async throws {
    let store = try await Fixture.store()
    var entry = Fixture.decision()
    entry.why = "Because"
    entry.writerLine = "Line"
    entry.rejectedAlternatives = ["x"]
    let old = try await seed(entry, in: store)
    let next = try await rewrite(old.id, NotebookRewrite(statement: "New", why: "  ", writerLine: "", rejectedAlternatives: []), in: store).get()
    #expect(next.why == nil)
    #expect(next.writerLine == nil)
    #expect(next.rejectedAlternatives.isEmpty)
  }

  @Test func shouldTurnASystemDetailIntoADecisionThatKeepsItsFields() async throws {
    let store = try await Fixture.store()
    let old = try await seed(NewNotebookEntry(kind: .system, topic: "organise.rules", statement: "s", why: "w", decidedBy: .system, stepKey: "organise"), in: store)
    let next = try await rewrite(old.id, NotebookRewrite(statement: "New"), in: store).get()
    #expect(next.entryKind == .known(.decision))
    #expect(next.decidedBy == .known(.author))
    #expect(next.why == "w")
    #expect(next.stepKey == "organise")
  }

  @Test(arguments: [LedgerEntryKind.direction, .rejected, .backlog])
  func shouldRefuseToRewriteAnythingButADecisionOrASystemDetailAsADecision(kind: LedgerEntryKind) async throws {
    let store = try await Fixture.store()
    let old = try await seed(NewNotebookEntry(kind: kind, topic: "t", statement: "s", decidedBy: .author), in: store)
    let failure = try await rewrite(old.id, NotebookRewrite(kind: .decision, statement: "New"), in: store).failure
    #expect(failure?.code == "LDG_003")
    #expect(failure?.errorDescription == "Only a decision or a system detail can be rewritten as a decision")
    #expect(try await Fixture.ledger(store).active().map(\.id) == [old.id])
  }

  @Test func shouldDropWhatBelongsToTheOldKindWhenTheKindChanges() async throws {
    let store = try await Fixture.store()
    var entry = Fixture.decision()
    entry.why = "Because"
    entry.payload = .object(["k": .int(1)])
    entry.links = NotebookLinks(entities: ["e"])
    entry.stepKey = "organise"
    let old = try await seed(entry, in: store)
    let next = try await rewrite(old.id, NotebookRewrite(kind: .direction, statement: "New"), in: store).get()
    #expect(next.entryKind == .known(.direction))
    #expect(next.why == nil)
    #expect(next.payload == nil)
    #expect(next.links == NotebookLinks())
    #expect(next.stepKey == nil)
  }

  @Test func shouldKeepTheIdeaAndScopeOfARewordedRejection() async throws {
    let store = try await Fixture.store()
    let anchor = JSONValue.object(["volumeKey": .string("one")])
    let old = try await seed(Fixture.rejection("i1", scope: .notNow, anchor: anchor), in: store)
    let next = try await rewrite(old.id, NotebookRewrite(statement: "Still no"), in: store).get()
    #expect(next.idea == "i1")
    #expect(next.rejectionScope == .known(.notNow))
    #expect(next.rejectionAnchor == anchor)
    #expect(next.topic == "idea.i1")
    #expect(try await Fixture.ledger(store).active().map(\.id) == [next.id])
  }

  @Test func shouldDropTheIdeaWhenARejectionBecomesABacklogItem() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.rejection("i1"), in: store)
    let next = try await rewrite(old.id, NotebookRewrite(kind: .backlog, statement: "Later"), in: store).get()
    #expect(next.idea == nil)
    #expect(next.rejectionScope == nil)
  }

  @Test func shouldRefuseAnEntryThatIsMissingOrRetired() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision(), in: store)
    _ = try await rewrite(old.id, NotebookRewrite(statement: "New"), in: store).get()
    #expect(try await rewrite(UUID(), NotebookRewrite(statement: "New"), in: store).failure?.code == "LDG_001")
    #expect(try await rewrite(old.id, NotebookRewrite(statement: "Again"), in: store).failure?.code == "LDG_002")
  }

  @Test func shouldRefuseAnEntryWrittenByANewerVersion() async throws {
    let store = try await Fixture.store()
    let id = UUID()
    let newer = NotebookEntryRecord(id: id, novel: Fixture.novel, entryKind: .unknown("x_idea"), topic: "t", statement: "s")
    _ = try await store.write { transaction in try newer.append(in: &transaction) }
    #expect(try await rewrite(id, NotebookRewrite(statement: "New"), in: store).failure?.code == "notebook.entry_not_understood")
  }

  @Test func shouldApplyTheLimitsOfTheReferenceRoute() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision(), in: store)
    let cases: [(NotebookRewrite, String)] = [
      (NotebookRewrite(statement: ""), "notebook.blank"),
      (NotebookRewrite(statement: String(repeating: "x", count: 4001)), "notebook.too_long"),
      (NotebookRewrite(statement: "s", why: String(repeating: "x", count: 4001)), "notebook.too_long"),
      (NotebookRewrite(statement: "s", writerLine: String(repeating: "x", count: 1001)), "notebook.too_long"),
      (NotebookRewrite(statement: "s", rejectedAlternatives: Array(repeating: "a", count: 21)), "notebook.too_many"),
      (NotebookRewrite(kind: .system, statement: "s"), "notebook.kind_not_allowed"),
    ]
    for (input, code) in cases { #expect(try await rewrite(old.id, input, in: store).failure?.code == code) }
    let accepted = NotebookRewrite(statement: "s", writerLine: String(repeating: "x", count: 1000), rejectedAlternatives: Array(repeating: "a", count: 20))
    #expect(try await rewrite(old.id, accepted, in: store).success != nil)
  }
}

@Suite("Notebook withdraw")
struct NotebookWithdrawTests {
  @Test func shouldDeactivateAnEntryWithoutASuccessor() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision(), in: store)
    let withdrawal = try await withdraw(old.id, "  Dropped  ", in: store).get()
    #expect(withdrawal.reason == "Dropped")
    #expect(withdrawal.entry == old.id)
    #expect(withdrawal.novel == Fixture.novel)
    let ledger = try await Fixture.ledger(store)
    #expect(ledger.active().isEmpty)
    #expect(ledger.entry(old.id)?.state == NotebookEntryState(successor: nil, withdrawal: withdrawal.id))
    #expect(ledger.entry(old.id)?.status == .withdrawn)
  }

  @Test func shouldRefuseAnEntryThatIsMissingOrRetired() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision(), in: store)
    #expect(try await withdraw(UUID(), in: store).failure?.code == "LDG_001")
    _ = try await withdraw(old.id, in: store).get()
    #expect(try await withdraw(old.id, in: store).failure?.code == "LDG_002")
    let next = try await seed(Fixture.decision("b"), in: store)
    _ = try await rewrite(next.id, NotebookRewrite(statement: "x"), in: store).get()
    #expect(try await withdraw(next.id, in: store).failure?.code == "LDG_002")
  }

  @Test func shouldRefuseAnEntryOfAnotherNovelAndAnUnknownNovel() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision(), in: store)
    #expect(try await withdraw(old.id, novel: Fixture.other, in: store).failure?.code == "PRJ_001")
    _ = try await store.write { transaction in try NovelRecord(id: Fixture.other, name: "Salt").create(in: &transaction) }
    #expect(try await withdraw(old.id, novel: Fixture.other, in: store).failure?.code == "LDG_001")
    #expect(try await Fixture.ledger(store).active().map(\.id) == [old.id])
  }

  @Test func shouldRequireAReasonOfAtMost4000Characters() async throws {
    let store = try await Fixture.store()
    let old = try await seed(Fixture.decision(), in: store)
    #expect(try await withdraw(old.id, "", in: store).failure?.code == "notebook.blank")
    #expect(try await withdraw(old.id, "  \n", in: store).failure?.code == "notebook.blank")
    #expect(try await withdraw(old.id, String(repeating: "r", count: 4001), in: store).failure?.code == "notebook.too_long")
    #expect(try await withdraw(old.id, String(repeating: "r", count: 4000), in: store).success != nil)
  }

  @Test func shouldLiftARejectionSoItIsNoLongerAnActiveDoNotProposeItem() async throws {
    let store = try await Fixture.store()
    let rejection = try await seed(Fixture.rejection("i1"), in: store)
    #expect(try await Fixture.ledger(store).sections().rejected.map(\.id) == [rejection.id])
    _ = try await withdraw(rejection.id, "Reconsidered", in: store).get()
    #expect(try await Fixture.ledger(store).sections().rejected.isEmpty)
  }
}
