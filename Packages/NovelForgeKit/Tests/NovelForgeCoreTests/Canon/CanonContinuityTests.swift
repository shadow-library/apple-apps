import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

private func store(entities: [String] = ["mira", "oren"]) async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
  try await write(store) { transaction in
    for key in entities { try CanonWrites.entity(novel: novel, key, in: &transaction) }
  }
  return store
}

private func finalize(_ chapter: Int, _ kept: [ProposedChange], in store: VaultStore) async throws {
  try await write(store) { transaction in try CanonWrites.finalize(novel: novel, chapter: chapter, review: review(kept), in: &transaction) }
}

private func expectRebuilt(_ store: VaultStore) async throws {
  let comparison = try await Projection.compare(try Projection.reconciler(chapterAreaDerivations), in: store)
  #expect(comparison.incremental == comparison.rebuilt)
}

/// apps/novel-forge-server/tests/ai/apply-continuity.spec.ts, with each delta a kept item of a winning canon's review (review-event-apply.ts:190-201).
@Suite("Canon character events", TestTimeLimit.standard)
struct CanonCharacterEventTests {
  // apply-continuity.spec.ts:87
  @Test func shouldRecordAStateEventWithThePriorStateAsBeforeAndTheReportedStateAsAfter() async throws {
    let store = try await store()
    try await finalize(4, [Kept.state("mira", location: "the harbour", conditions: ["tired"], goal: "find the lamp")], in: store)
    try await finalize(5, [Kept.state("mira", location: "the tower", conditions: [], note: "resolved")], in: store)
    let events = try await CanonTables.events(novel, in: store)
    #expect(
      events.contains(
        EventView(
          "mira", 5, .state, before: stateJSON(location: "the harbour", conditions: ["tired"], goal: "find the lamp"),
          after: stateJSON(location: "the tower", conditions: [], note: "resolved"))))
    #expect(try await CanonTables.states(novel, in: store) == [StateView("mira", location: "the tower", conditions: [], note: "resolved", chapter: 5)])
    try await expectRebuilt(store)
  }

  // apply-continuity.spec.ts:112
  @Test func shouldRecordANullBeforeStateEventTheFirstTimeACharactersStateIsReported() async throws {
    let store = try await store()
    try await finalize(3, [Kept.state("mira", location: "the tower")], in: store)
    #expect(try await CanonTables.events(novel, in: store) == [EventView("mira", 3, .state, before: nil, after: stateJSON(location: "the tower"))])
  }

  // apply-continuity.spec.ts:123: the reference skips a low-confidence report; here the author's skip leaves it out of the kept set
  @Test func shouldRecordNothingForAReportedStateTheReviewDidNotKeep() async throws {
    let store = try await store()
    try await finalize(3, [], in: store)
    #expect(try await CanonTables.events(novel, in: store).isEmpty)
    #expect(try await CanonTables.states(novel, in: store).isEmpty)
  }

  // apply-continuity.spec.ts:134
  @Test func shouldKeepBeforeAndRefreshOnlyAfterWhenTheSameEventIsReportedAgain() throws {
    let binding = try CanonBinding(
      CanonBindingEntry(
        key: try FinalChapterRecord.ref(novel: novel, chapter: 5).key, novel: novel, chapter: 5, clock: try stamp(2),
        kept: CanonJSON.text(.array([Kept.state("mira", location: "the harbour"), Kept.state("mira", location: "the tower")].map(\.json))), knowledgeState: .absent,
        knowledge: nil))
    let replayed = CanonCharacters.replay(novel: novel, bindings: [binding], liveSince: [JSString("mira"): try stamp(1)])
    let events = try replayed.events.map(EventView.init)
    #expect(events == [EventView("mira", 5, .state, before: nil, after: stateJSON(location: "the tower"))])
  }

  // apply-continuity.spec.ts:148
  @Test func shouldRecordAnAppearanceEventForEachEntityNewlySeenThisChapter() async throws {
    let store = try await store()
    try await finalize(5, [Kept.appearance("mira"), Kept.appearance("oren")], in: store)
    #expect(try await CanonTables.appearances(novel, in: store) == ["mira@5", "oren@5"])
    let appeared = [EventView("mira", 5, .appearance, before: nil, after: nil), EventView("oren", 5, .appearance, before: nil, after: nil)]
    #expect(try await CanonTables.events(novel, in: store) == Set(appeared))
  }

  // apply-continuity.spec.ts:163, and :105 (a new entity appears in the chapter that introduces it)
  @Test func shouldRecordOneAppearanceWhenTheChapterAlreadyRecordedTheEntity() async throws {
    let store = try await store()
    try await finalize(5, [Kept.entity("mira"), Kept.appearance("mira")], in: store)
    #expect(try await CanonTables.appearances(novel, in: store) == ["mira@5"])
    #expect(try await CanonTables.events(novel, in: store) == [EventView("mira", 5, .appearance, before: nil, after: nil)])
  }

  // apply-continuity.spec.ts:171
  @Test func shouldRecordARelationshipEventKeyedByTargetAndKindWithThePriorNoteAsBefore() async throws {
    let store = try await store()
    try await finalize(4, [Kept.relationship("mira", "oren", "ally", note: "wary allies")], in: store)
    try await finalize(6, [Kept.relationship("mira", "oren", "ally", note: "trusted allies")], in: store)
    #expect(
      try await CanonTables.events(novel, in: store).contains(
        EventView("mira", 6, .relationship, detail: "oren:ally", before: edgeJSON("oren", "ally", note: "wary allies"), after: edgeJSON("oren", "ally", note: "trusted allies"))))
    #expect(try await CanonTables.relationships(novel, in: store) == ["mira→oren:ally@4 wary allies", "mira→oren:ally@6 trusted allies"])
  }

  // apply-continuity.spec.ts:194: the newest earlier chapter, never this chapter's own row; apply-continuity.ts:271 keeps a same-chapter note the report omits
  @Test func shouldReadARelationshipsBeforeFromTheNewestEarlierChapterOnly() async throws {
    let store = try await store()
    try await finalize(2, [Kept.relationship("mira", "oren", "ally", note: "strangers")], in: store)
    try await finalize(4, [Kept.relationship("mira", "oren", "ally", note: "wary allies")], in: store)
    try await finalize(6, [Kept.relationship("mira", "oren", "ally", note: "trusted allies"), Kept.relationship("mira", "oren", "ally")], in: store)
    let events = try await CanonTables.events(novel, in: store).filter { $0.chapter == 6 }
    let before = edgeJSON("oren", "ally", note: "wary allies")
    #expect(events == [EventView("mira", 6, .relationship, detail: "oren:ally", before: before, after: edgeJSON("oren", "ally", note: "trusted allies"))])
    #expect(try await CanonTables.relationships(novel, in: store).contains("mira→oren:ally@6 trusted allies"))
  }

  // apply-continuity.spec.ts:217
  @Test func shouldRecordNoRelationshipWhenTheSourceOrTargetCannotBeResolved() async throws {
    let store = try await store(entities: ["mira"])
    try await finalize(6, [Kept.relationship("mira", "ghost", "ally", note: "trusted"), Kept.relationship("ghost", "mira", "ally")], in: store)
    #expect(try await CanonTables.events(novel, in: store).isEmpty)
    #expect(try await CanonTables.relationships(novel, in: store).isEmpty)
  }

  // apply-continuity.ts:293-297 resolves the entity at the commit, and its rows go with it (database/schemas/knowledge.ts, entity_id cascades)
  @Test func shouldStartAnEntityRemovedOrCreatedAfterTheCanonWithNothing() async throws {
    let store = try await store(entities: ["mira"])
    try await finalize(1, [Kept.appearance("mira"), Kept.state("mira", location: "the pier"), Kept.appearance("oren")], in: store)
    try await write(store) { transaction in try CanonWrites.entity(novel: novel, "oren", in: &transaction) }
    #expect(try await CanonTables.appearances(novel, in: store) == ["mira@1"])
    try await write(store) { transaction in try CanonWrites.removeEntity(novel: novel, "mira", in: &transaction) }
    #expect(try await CanonTables.appearances(novel, in: store).isEmpty)
    #expect(try await CanonTables.states(novel, in: store).isEmpty)
    try await write(store) { transaction in try CanonWrites.entity(novel: novel, "mira", in: &transaction) }
    #expect(try await CanonTables.appearances(novel, in: store).isEmpty)
    try await finalize(2, [Kept.appearance("mira")], in: store)
    #expect(try await CanonTables.appearances(novel, in: store) == ["mira@2"])
    try await expectRebuilt(store)
  }

  // review-event-apply.ts:190-226 applies nothing for a chapter finalized without a review, or a review this version cannot read
  @Test func shouldDeriveNothingFromACanonWithoutAReadableReview() async throws {
    let store = try await store()
    try await write(store) { transaction in
      try CanonWrites.finalize(novel: novel, chapter: 1, review: nil, in: &transaction)
      try CanonWrites.finalize(novel: novel, chapter: 2, unreadable: .review, in: &transaction)
    }
    #expect(try await Projection.fetch(CanonBindingEntry.all(), in: store).isEmpty)
    #expect(try await CanonTables.appearances(novel, in: store).isEmpty)
  }
}

private let ledger = "ledger"

private func thread(status: ThreadStatus, summary: String? = "Old.", closed: Int? = nil, dormant: Bool = false) -> ThreadRecord {
  ThreadRecord(novel: novel, thread: ledger, summary: summary, openedChapter: 2, status: ThreadProgress(state: .known(status), chapter: closed), dormant: dormant)
}

private func promises(_ record: ThreadRecord?, then kept: [ProposedChange], at chapter: Int = 5) async throws -> [String: PromiseView] {
  let store = try await store(entities: [])
  if let record { try await write(store) { transaction in _ = try record.create(in: &transaction) } }
  try await finalize(chapter, kept, in: store)
  return try await CanonTables.promises(novel, in: store)
}

/// apps/novel-forge-server/tests/ai/apply-continuity-promises.spec.ts; its row lock (:61) has no counterpart, as the author's register and the canon's observation
/// never share a write.
@Suite("Canon promise observations", TestTimeLimit.standard)
struct CanonPromiseTests {
  // apply-continuity-promises.spec.ts:74
  @Test func shouldNeverReopenADroppedThread() async throws {
    let state = try await promises(thread(status: .dropped), then: [Kept.thread(ledger, .open, summary: "Mira found the ledger.")])
    #expect(state["thread:ledger"]?.status == "dropped")
  }

  // apply-continuity-promises.spec.ts:84
  @Test func shouldNeverMarkADroppedThreadClosed() async throws {
    let state = try await promises(thread(status: .dropped), then: [Kept.thread(ledger, .closed, summary: "Mira found the ledger.")])
    #expect(state["thread:ledger"]?.status == "dropped")
    #expect(state["thread:ledger"]?.closed == nil)
  }

  // apply-continuity-promises.spec.ts:94
  @Test func shouldNeverUnSilenceAThreadTheAuthorMarkedDormant() async throws {
    let state = try await promises(thread(status: .open, dormant: true), then: [Kept.thread(ledger, .open, summary: "Mira found the ledger.", open: false)])
    #expect(state["thread:ledger"]?.open == true)
  }

  // apply-continuity-promises.spec.ts:102
  @Test func shouldStillCloseAnOrdinaryOpenThread() async throws {
    let state = try await promises(thread(status: .open), then: [Kept.thread(ledger, .closed, summary: "Mira burned the ledger.")])
    #expect(state["thread:ledger"] == PromiseView(ledger, "closed", opened: 2, closed: 5, text: "Mira burned the ledger.", advanced: 5))
  }

  // apply-continuity-promises.spec.ts:110
  @Test func shouldNeverReopenADroppedMystery() async throws {
    let store = try await store(entities: [])
    try await write(store) { transaction in
      _ = try MysteryRecord(novel: novel, mystery: "who-took-it", question: "Who took the ledger?", status: MysteryProgress(state: .known(.dropped))).create(in: &transaction)
    }
    try await finalize(5, [Kept.mystery("who-took-it", .resolved, question: "Who took the ledger?")], in: store)
    let state = try await CanonTables.promises(novel, in: store)["mystery:who-took-it"]
    #expect(state?.status == "dropped")
    #expect(state?.closed == nil)
  }

  // apply-continuity.ts:153-167: the first observation creates the promise; a later one without a summary keeps it; reopening keeps the closed chapter
  @Test func shouldCreateAPromiseTheAuthorNeverRecordedAndKeepWhatALaterObservationOmits() async throws {
    let store = try await store(entities: [])
    try await finalize(3, [Kept.thread(ledger, .closed, summary: "The ledger burns."), Kept.mystery("who", .open)], in: store)
    try await finalize(4, [Kept.thread(ledger, .open), Kept.mystery("who", .resolved, question: "", truth: "heir")], in: store)
    let state = try await CanonTables.promises(novel, in: store)
    #expect(state["thread:ledger"] == PromiseView(ledger, "open", opened: 3, closed: 3, text: "The ledger burns.", advanced: 4))
    #expect(state["mystery:who"] == PromiseView("who", "resolved", opened: 3, closed: 4, text: "", truth: "heir", advanced: 4))
  }

  // apply-continuity.ts:151: a promise created by an observation takes its intentionally-open flag, false when absent
  @Test func shouldTakeTheFirstObservationsIntentionallyOpenFlag() async throws {
    let state = try await promises(nil, then: [Kept.thread(ledger, .open, summary: "S.", open: true)])
    #expect(state["thread:ledger"]?.open == true)
  }

  // Native: the author's register written after the canon outranks the canon's observation, as an edit after finalize would in the reference
  @Test func shouldLetTheAuthorsLaterEditOutrankAnObservation() async throws {
    let clock = SchemaTestClock()
    let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations), clock: clock)
    try await write(store) { transaction in _ = try thread(status: .open).create(in: &transaction) }
    clock.advance()
    try await finalize(5, [Kept.thread(ledger, .closed, summary: "Burned.")], in: store)
    #expect(try await CanonTables.promises(novel, in: store)["thread:ledger"]?.status == "closed")
    clock.advance()
    var edit = ThreadEdit()
    edit.status = .set(ThreadProgress(state: .known(.open)))
    let changes = edit
    try await write(store) { transaction in _ = try ThreadRecord.edit(novel: novel, thread: ledger, changes, in: &transaction) }
    #expect(try await CanonTables.promises(novel, in: store)["thread:ledger"] == PromiseView(ledger, "open", opened: 2, text: "Burned.", advanced: 5))
    try await write(store) { transaction in _ = try ThreadRecord.remove(novel: novel, thread: ledger, in: &transaction) }
    #expect(try await CanonTables.promises(novel, in: store).isEmpty)
    try await expectRebuilt(store)
  }

  // promise.handler.ts:196-197 deletes the row, and apply-continuity.ts:153-168 creates it again from a later observation
  @Test func shouldCreateARemovedPromiseAfreshFromALaterObservationOnly() async throws {
    let clock = SchemaTestClock()
    let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations), clock: clock)
    try await write(store) { transaction in _ = try thread(status: .open).create(in: &transaction) }
    clock.advance()
    try await finalize(3, [Kept.thread(ledger, .closed, summary: "Burned.")], in: store)
    clock.advance()
    try await write(store) { transaction in _ = try ThreadRecord.remove(novel: novel, thread: ledger, in: &transaction) }
    #expect(try await CanonTables.promises(novel, in: store).isEmpty)
    clock.advance()
    try await finalize(5, [Kept.thread(ledger, .open, summary: "Found again.")], in: store)
    #expect(try await CanonTables.promises(novel, in: store)["thread:ledger"] == PromiseView(ledger, "open", opened: 5, text: "Found again.", advanced: 5))
    try await expectRebuilt(store)
  }

  @Test func shouldIgnoreObservationsOlderThanARestoredRecord() async throws {
    let clock = SchemaTestClock()
    let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations), clock: clock)
    let record = thread(status: .open)
    try await write(store) { transaction in _ = try record.create(in: &transaction) }
    clock.advance()
    try await finalize(3, [Kept.thread(ledger, .closed, summary: "Burned.")], in: store)
    clock.advance()
    try await write(store) { transaction in _ = try ThreadRecord.remove(novel: novel, thread: ledger, in: &transaction) }
    clock.advance()
    try await write(store) { transaction in _ = try record.restore(in: &transaction) }
    #expect(try await CanonTables.promises(novel, in: store)["thread:ledger"] == PromiseView(ledger, "open", opened: 2, text: "Old."))
  }

  // apply-continuity.ts:215: an empty reported question never replaces the one the author wrote
  @Test func shouldKeepTheAuthorsMysteryQuestionOverAnEmptyObservedOne() async throws {
    let store = try await store(entities: [])
    try await write(store) { transaction in
      _ = try MysteryRecord(novel: novel, mystery: "who", question: "Who took the ledger?", openedChapter: 1).create(in: &transaction)
    }
    try await finalize(5, [Kept.mystery("who", .open, question: "")], in: store)
    #expect(try await CanonTables.promises(novel, in: store)["mystery:who"] == PromiseView("who", "open", opened: 1, text: "Who took the ledger?", advanced: 5))
  }
}
