import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private enum Turn {
  static let reply = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000f1")
  static let message = "Mara is a thief who works the Saltgate docks."
  static let maraThief = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","status":"thief","quote":"Mara is a thief who works the Saltgate docks"}"#
  static let kael = #"{"op":"entity.upsert","entityKey":"kael","type":"character","name":"Kael","body":"Kael the smith."}"#
  static let removeRise = #"{"op":"milestone.remove","milestoneKey":"rise"}"#
  static let approve3 = #"{"op":"action.approve_draft","chapter":3}"#
  static let organise = #"{"op":"action.organise_notes"}"#

  static func request(
    _ ops: String..., novel: UUID, mode: RefinementChatMode = .auto, justDiscussing: Bool = false, organise: OrganiseRouting = .none, warnings: [String] = [],
    message: String = message, now: Date
  ) throws -> TurnStagingRequest {
    let changeSet = try #require(try OrderedJSON(parsing: "[\(ops.joined(separator: ","))]").arrayValue).map { try #require($0.objectValue) }
    return TurnStagingRequest(
      novel: novel, session: StagingWorld.session, reply: reply, replyText: "Done — I noted it.\nMore below.", changeSet: changeSet, authorMessage: message,
      mode: mode, justDiscussing: justDiscussing, organise: organise, contexts: [], warnings: warnings, run: "run-1", now: now)
  }
}

extension ChapterBook {
  fileprivate func turn(_ request: TurnStagingRequest) async throws -> TurnStagingResult {
    let result = try await store.stageTurn(request)
    try await Projection.expectNoFaults(in: store)
    return result
  }

  fileprivate func pendingCards() async throws -> [UUID] {
    try await store.read { transaction in
      try ProposalRecord.listing(in: transaction).entries.map(\.record).filter { $0.decision == .known(.pending) }.map(\.id)
    }
  }

  fileprivate func ops(of proposal: UUID) async throws -> [ChangeOp] {
    try await self.proposal(proposal).card.changeSet.compactMap(\.op)
  }
}

private func types(_ ops: [ChangeOp]) -> [OpType] {
  ops.map(\.type)
}

private func changeOps(_ ops: String...) throws -> [ChangeOp] {
  try parseChangeSet(try OrderedJSON(parsing: "[\(ops.joined(separator: ","))]"), options: ChangeSetValidationOptions(entityMaterialization: false))
}

private func unreadable(_ key: NovelForgeKey, in store: VaultStore) async throws {
  _ = try await store.write { transaction in try transaction.set(key.ref, ["natural_key": key.stored, "removed": .bool(false)]) }
}

private func movedHead(_ chapter: Int, in book: ChapterBook) async throws {
  try await book.save(chapter, "Mine.\n\n\(StagingText.body)", summary: "It turns.", base: try await book.head(chapter))
  try await book.reviseElsewhere(chapter, "Theirs.\n\n\(StagingText.body)")
}

private func movedWhy(_ chapter: Int) -> String? {
  ProposalStagingError.approvalOverMovedDraft(chapter: chapter).errorDescription
}

// apps/novel-forge-server/src/modules/refinement/turn-proposals.ts:127-174 and chat-turn-staging.service.ts:46-149 over the store
@Suite("Turn staging over the store")
struct TurnStagingStoreTests {
  @Test func shouldApplyTheAuthorsWordsAndStageTheRestAsOneCardAfterwards() async throws {
    let book = try await StagingWorld.book()
    let result = try await book.turn(try Turn.request(Turn.maraThief, Turn.removeRise, novel: book.novel, now: book.clock.now))

    let applied = try #require(result.appliedProposal)
    let card = try #require(result.cardProposal)
    #expect(result.applied == [ProposalChangeOutcome(index: 0, status: .applied, source: .quoted)])
    #expect(result.applyNote == nil && result.held == nil && result.replyNote == nil)
    let appliedRecord = try await book.proposal(applied)
    #expect(appliedRecord.decision == .known(.applied))
    #expect(appliedRecord.application?.automatic == true)
    #expect(appliedRecord.card.message == Turn.reply && appliedRecord.card.session == StagingWorld.session)
    #expect(appliedRecord.card.kind == .known(.hub) && appliedRecord.card.summary == "Done — I noted it.")
    #expect(types(try await book.ops(of: applied)) == [.entityUpsert])
    #expect(types(try await book.ops(of: card)) == [.milestoneRemove])
    #expect(try await book.pendingCards() == [card])
    #expect(try await book.entity("mara")?.status == "thief")
  }

  @Test func shouldStageEveryOpAsACardWhenTheAuthorIsJustDiscussing() async throws {
    let book = try await StagingWorld.book()
    let result = try await book.turn(try Turn.request(Turn.maraThief, Turn.kael, novel: book.novel, justDiscussing: true, now: book.clock.now))

    #expect(result.appliedProposal == nil)
    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.entityUpsert, .entityUpsert])
    #expect(try await book.proposalCount() == 1)
  }

  @Test func shouldHoldTheTurnForReviewWhenItCarriesAWarning() async throws {
    let book = try await StagingWorld.book()
    let result = try await book.turn(try Turn.request(Turn.maraThief, novel: book.novel, warnings: ["echo"], now: book.clock.now))

    #expect(result.appliedProposal == nil && result.cardProposal != nil)
    #expect(result.applyNote == heldForReviewNote && result.held == .warnings)
    #expect(try await book.proposal(try #require(result.cardProposal)).card.warnings.contains("echo"))
  }

  // turn-proposals.ts:154-156: the direct card is rolled back with its transaction, so only the cards stand and nothing was applied
  @Test func shouldTurnEveryOpIntoACardWhenTheAutomaticApplyIsRefusedLeavingNoOtherProposal() async throws {
    let book = try await StagingWorld.book()
    let ghostMilestone = #"{"op":"milestone.upsert","milestoneKey":"heist","label":"The heist","subjectEntityKey":"nobody"}"#
    let result = try await book.turn(try Turn.request(ghostMilestone, Turn.removeRise, novel: book.novel, now: book.clock.now))

    #expect(result.appliedProposal == nil)
    let card = try #require(result.cardProposal)
    #expect(types(try await book.ops(of: card)) == [.milestoneUpsert, .milestoneRemove])
    #expect(result.applyNote != nil && result.applyNote != applyFailedNote)
    #expect(result.held == nil)
    #expect(try await book.proposalCount() == 1)
    #expect(try await book.pendingCards() == [card])
  }

  // State file, F15 rule: an approval over a working copy resting on a moved head refuses the staging; it is retried without the approval, never all as cards
  @Test func shouldStageTheCardsWithoutAnApprovalOverAMovedHeadAndSayWhy() async throws {
    let book = try await StagingWorld.workspace()
    try await book.save(3, "Mine.\n\n\(StagingText.body)", summary: "It turns.", base: try await book.head(3))
    try await book.reviseElsewhere(3, "Theirs.\n\n\(StagingText.body)")
    let result = try await book.turn(try Turn.request(Turn.maraThief, Turn.approve3, Turn.removeRise, novel: book.novel, now: book.clock.now))

    let why = ProposalStagingError.approvalOverMovedDraft(chapter: 3).errorDescription
    #expect(result.appliedProposal != nil)
    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.milestoneRemove])
    #expect(result.replyNote == why)
    #expect(result.applyNote == nil)
    #expect(try await book.proposalCount() == 2)
  }

  @Test func shouldStageNoCardWhenTheOnlyOpWasAnApprovalOverAMovedHead() async throws {
    let book = try await StagingWorld.workspace()
    try await book.save(3, "Mine.\n\n\(StagingText.body)", summary: "It turns.", base: try await book.head(3))
    try await book.reviseElsewhere(3, "Theirs.\n\n\(StagingText.body)")
    let result = try await book.turn(try Turn.request(Turn.approve3, novel: book.novel, now: book.clock.now))

    #expect(result.appliedProposal == nil && result.cardProposal == nil)
    #expect(result.replyNote == ProposalStagingError.approvalOverMovedDraft(chapter: 3).errorDescription)
    #expect(result.applyNote == nil && result.held == nil)
    #expect(try await book.proposalCount() == 0)
  }

  // State file, F11a rule 6: an op on a record this device cannot read always waits for the author
  @Test func shouldCardAnOpOnARecordThisDeviceCannotRead() async throws {
    let book = try await StagingWorld.book()
    let key = NovelForgeKey.entityKey(novel: book.novel, entity: "ghost")
    try await book.run { _ = try $0.set(key.ref, ["natural_key": key.stored, "removed": .bool(false)]) }
    let ghost = #"{"op":"entity.upsert","entityKey":"ghost","type":"character","name":"Ghost","status":"thief","quote":"Ghost is a thief who works the Saltgate docks"}"#
    let message = "\(Turn.message) Ghost is a thief who works the Saltgate docks."
    let result = try await book.turn(try Turn.request(Turn.maraThief, ghost, novel: book.novel, message: message, now: book.clock.now))

    #expect(result.applied == [ProposalChangeOutcome(index: 0, status: .applied, source: .quoted)])
    #expect(types(try await book.ops(of: try #require(result.appliedProposal))) == [.entityUpsert])
    let card = try await book.ops(of: try #require(result.cardProposal))
    #expect(card.map { changeSetRefs([$0]) } == [["entity:ghost"]])
    #expect(result.held == nil)
  }

  @Test func shouldStageTheOrganiseActionAsACardItCannotStartOnItsOwn() async throws {
    let book = try await StagingWorld.book()
    let result = try await book.turn(try Turn.request(Turn.organise, novel: book.novel, organise: .start, now: book.clock.now))

    #expect(result.appliedProposal == nil)
    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.actionOrganiseNotes])
    #expect(result.replyNote == "\(organiseRefusedNote) Applying action.organise_notes is not yet available.")
    #expect(result.applyNote == nil)
  }

  @Test func shouldLeaveOutARewriteItCannotPlaceAndNameItInTheReply() async throws {
    let book = try await StagingWorld.workspace()
    let missing = StagingText.rewrite("words that are nowhere in the chapter", "new words")
    let result = try await book.turn(try Turn.request(missing, Turn.removeRise, novel: book.novel, now: book.clock.now))

    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.milestoneRemove])
    #expect(result.replyNote == "Forge left out a passage rewrite:\n- A passage in chapter 3: \(RewriteDropReason.notFound.why).")
  }

  @Test func shouldStageNothingWhenEveryRewriteWasLeftOut() async throws {
    let book = try await StagingWorld.workspace()
    let result = try await book.turn(try Turn.request(StagingText.rewrite("nowhere at all", "x"), novel: book.novel, now: book.clock.now))

    #expect(result.appliedProposal == nil && result.cardProposal == nil && result.applyNote == nil)
    #expect(result.replyNote?.hasPrefix("Forge left out a passage rewrite:") == true)
    #expect(try await book.proposalCount() == 0)
  }

  // chat-turn-staging.service.ts:132
  @Test func shouldLeaveOutAnIdeaTheAuthorTurnedDownAndSaySo() async throws {
    let book = try await StagingWorld.book()
    let first = try await book.turn(try Turn.request(Turn.kael, novel: book.novel, mode: .manual, now: book.clock.now))
    let card = try #require(first.cardProposal)
    _ = try await book.store.rejectIdea(proposal: card, opIndex: 0, scope: .never, novel: book.novel)
    let count = try await book.proposalCount()

    let again = try await book.turn(try Turn.request(Turn.kael, novel: book.novel, now: book.clock.now))
    #expect(again == TurnStagingResult(applyNote: ideasDroppedNote))
    #expect(try await book.proposalCount() == count)

    let alongside = try await book.turn(try Turn.request(Turn.maraThief, Turn.kael, novel: book.novel, now: book.clock.now))
    #expect(types(try await book.ops(of: try #require(alongside.appliedProposal))) == [.entityUpsert])
    #expect(alongside.cardProposal == nil && alongside.applyNote == ideasDroppedNote)
  }

  // turn-proposals.ts:126: a later turn's card replaces the session's earlier one on the same record, so the session never holds two overlapping pending cards
  @Test func shouldReplaceTheSessionsEarlierCardOnTheSameRecord() async throws {
    let book = try await StagingWorld.book()
    let first = try await book.turn(try Turn.request(Turn.kael, novel: book.novel, mode: .manual, now: book.clock.now))
    let second = try await book.turn(try Turn.request(Turn.kael, Turn.removeRise, novel: book.novel, mode: .manual, now: book.clock.now))

    #expect(try await book.decision(try #require(first.cardProposal)) == .known(.superseded))
    #expect(try await book.pendingCards() == [try #require(second.cardProposal)])
  }

  // turn-proposals.ts:146-148. The write policy keeps an undating fact a card, so the split that sends one to the direct side is built by hand.
  @Test func shouldStageEveryOpAsOneCardWhenTheDirectSideRaisesAWarningOfItsOwn() async throws {
    let book = try await StagingWorld.book()
    let ops = try changeOps(#"{"op":"fact.upsert","factKey":"heir","revealChapter":null}"#, Turn.removeRise)
    let split = ChangeSetSplit(
      ops: ops, direct: [ops[0]], cards: [ops[1]], sources: [.quoted],
      dispositions: [.direct(index: 0, source: .quoted), .card(index: 1, reason: .alwaysCard, rule: .removal)], held: .none)
    let steps = TurnStoreSteps(store: book.store, request: try Turn.request(Turn.removeRise, novel: book.novel, now: book.clock.now))
    let result = try await TurnStagingFlow.stage(split, warnings: [], steps: steps)

    #expect(result.appliedProposal == nil && result.applied == nil)
    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.factUpsert, .milestoneRemove])
    #expect(result.applyNote == heldForReviewNote && result.held == .warnings)
    #expect(try await book.proposalCount() == 1)
  }

  // turn-proposals.ts:108: a Notebook entry this device cannot read may be the rejection of this very idea, so no idea applies
  @Test func shouldKeepEveryIdeaACardWhenANotebookEntryCannotBeRead() async throws {
    let control = try await StagingWorld.book()
    #expect(try await control.turn(try Turn.request(Turn.kael, novel: control.novel, now: control.clock.now)).appliedProposal != nil)

    let book = try await StagingWorld.book()
    let novel = book.novel
    _ = try await book.store.write { transaction in
      try transaction.append(NovelForgeKey.notebookEntry(UUID()), item: ["novel": .string(novel.uuidString.lowercased())])
    }
    let result = try await book.store.stageTurn(try Turn.request(Turn.kael, novel: novel, now: book.clock.now))

    #expect(result.appliedProposal == nil)
    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.entityUpsert])
  }

  @Test func shouldFailTheRejectionReadOverAVolumeOrAnAnchoredRecordItCannotRead() async throws {
    let book = try await StagingWorld.book()
    let novel = book.novel
    let ghost = #"{"op":"entity.upsert","entityKey":"ghost","type":"character","name":"Ghost"}"#
    let kaelId = try #require(IdeaIdentity.shared).ideaId(of: try #require(try changeOps(Turn.kael).first))
    let ghostId = try #require(IdeaIdentity.shared).ideaId(of: try #require(try changeOps(ghost).first))
    let card = try #require(try await book.turn(try Turn.request(Turn.kael, ghost, novel: novel, mode: .manual, now: book.clock.now)).cardProposal)
    _ = try await book.store.rejectIdea(proposal: card, opIndex: 0, scope: .never, novel: novel)
    _ = try await book.store.rejectIdea(proposal: card, opIndex: 1, scope: .notThisVersion, novel: novel)
    let read = { (ids: [String]) async throws -> Set<JSString>? in
      try await book.store.write { transaction in TurnStagingPlan.rejectedIdeas(ids, novel: novel, in: transaction) }
    }
    #expect(try await read([kaelId]) == [JSString(kaelId)])
    #expect(try await read([ghostId]) == [JSString(ghostId)])

    try await unreadable(NovelForgeKey.entityKey(novel: novel, entity: "ghost"), in: book.store)
    #expect(try await read([ghostId]) == nil)
    #expect(try await read([kaelId]) == [JSString(kaelId)])
    try await unreadable(NovelForgeKey.volumeKey(novel: novel, volume: "broken"), in: book.store)
    #expect(try await read([kaelId]) == nil)
  }

  @Test func shouldFailTheRejectionReadOverAScopeOrAnchorThisVersionDoesNotKnow() async throws {
    let book = try await StagingWorld.book()
    let novel = book.novel
    let kaelId = try #require(IdeaIdentity.shared).ideaId(of: try #require(try changeOps(Turn.kael).first))
    let read = { (ids: [String]) async throws -> Set<JSString>? in
      try await book.store.write { transaction in TurnStagingPlan.rejectedIdeas(ids, novel: novel, in: transaction) }
    }
    let entry = { (scope: StoredEnum<LedgerRejectionScope>, anchor: JSONValue?) in
      NotebookEntryRecord(
        novel: novel, entryKind: .known(.rejected), topic: NotebookTopics.idea(kaelId), statement: "Kael", idea: kaelId, rejectionScope: scope, rejectionAnchor: anchor)
    }
    let unknownScope = entry(.unknown("someday"), nil)
    _ = try await book.store.write { transaction in try unknownScope.append(in: &transaction) }
    #expect(try await read([kaelId]) == nil)

    let other = try await StagingWorld.book()
    let unknownAnchor = entry(.known(.notNow), .string("v1"))
    _ = try await other.store.write { transaction in try unknownAnchor.append(in: &transaction) }
    #expect(try await other.store.write { transaction in TurnStagingPlan.rejectedIdeas([kaelId], novel: novel, in: transaction) } == nil)
    let result = try await other.store.stageTurn(try Turn.request(Turn.kael, novel: novel, now: other.clock.now))
    #expect(result.appliedProposal == nil && result.cardProposal != nil)
  }

  @Test func shouldLeaveOutOnlyTheApprovalOverTheMovedHead() async throws {
    let book = try await StagingWorld.workspace()
    try await book.draft(4, StagingText.body)
    try await movedHead(3, in: book)
    let approve4 = #"{"op":"action.approve_draft","chapter":4}"#
    let result = try await book.turn(try Turn.request(Turn.approve3, approve4, novel: book.novel, now: book.clock.now))

    let card = try await book.ops(of: try #require(result.cardProposal))
    #expect(card.map { ProposalStamps.approvalChapters([$0]) } == [[4]])
    #expect(result.replyNote == movedWhy(3))
  }

  @Test func shouldLeaveOutEveryApprovalOverAMovedHeadSayingWhyForEach() async throws {
    let book = try await StagingWorld.workspace()
    try await movedHead(3, in: book)
    try await book.draft(4, StagingText.body)
    try await movedHead(4, in: book)
    let approve4 = #"{"op":"action.approve_draft","chapter":4}"#
    let result = try await book.turn(try Turn.request(Turn.approve3, approve4, Turn.removeRise, novel: book.novel, now: book.clock.now))

    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.milestoneRemove])
    #expect(result.replyNote == [movedWhy(3), movedWhy(4)].compactMap { $0 }.joined(separator: "\n\n"))
  }

  // turn-proposals.ts:171-172: why an approval was left out still reaches the reply when the card then fails for another reason
  @Test func shouldCarryWhyAnApprovalWasLeftOutWhenTheCardThenFails() async throws {
    let book = try await StagingWorld.workspace()
    try await movedHead(3, in: book)
    let ops = try changeOps(Turn.approve3, StagingText.rewrite("words that are nowhere in the chapter", "new words"))
    let steps = TurnStoreSteps(store: book.store, request: try Turn.request(Turn.approve3, novel: book.novel, now: book.clock.now))

    do throws(TurnStagingError) {
      _ = try await steps.stageCards(ops, warnings: [], entityMaterialization: true) { _ in TurnStagingNotes() }
      Issue.record("the card staged a rewrite it cannot place")
    } catch {
      guard case .unsaved(.staging(.rewriteNotPlaced(chapter: 3, reason: .notFound)), let notes) = error else {
        Issue.record("unexpected \(error)")
        return
      }
      #expect(notes == [movedWhy(3)].compactMap { $0 })
    }
    #expect(try await book.proposalCount() == 0)
  }

  @Test func shouldLeaveOutARewriteOfADraftThisDeviceCannotRead() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    _ = try await book.store.write { transaction in _ = try transaction.revise(try DraftRecord.ref(novel: novel, chapter: 3), body: .object([:])) }
    let rewrite = StagingText.rewrite(StagingText.fear, StagingText.fearRewrite)
    let result = try await book.store.stageTurn(try Turn.request(rewrite, Turn.removeRise, novel: novel, now: book.clock.now))

    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.milestoneRemove])
    #expect(result.replyNote == "Forge left out a passage rewrite:\n- A passage in chapter 3: \(RewriteDropReason.unreadable.why).")
  }

  // chat-turn-staging.service.ts:111: a turn held whole goes through the split, where the organise action is a card like any action
  @Test func shouldSplitAnOrganiseTurnTheWarningsHoldWhole() async throws {
    let book = try await StagingWorld.book()
    let result = try await book.turn(try Turn.request(Turn.organise, novel: book.novel, organise: .start, warnings: ["echo"], now: book.clock.now))

    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.actionOrganiseNotes])
    #expect(result.replyNote == nil && result.appliedProposal == nil)
  }

  // State file, F11a rule 6, through the refs an op names: a milestone on an entity this device cannot read waits for the author
  @Test func shouldCardAnOpThatNamesARecordThisDeviceCannotRead() async throws {
    let book = try await StagingWorld.book()
    try await unreadable(NovelForgeKey.entityKey(novel: book.novel, entity: "ghost"), in: book.store)
    let heist = #"{"op":"milestone.upsert","milestoneKey":"heist","label":"The heist","subjectEntityKey":"ghost"}"#
    let result = try await book.turn(try Turn.request(Turn.maraThief, heist, novel: book.novel, now: book.clock.now))

    #expect(types(try await book.ops(of: try #require(result.appliedProposal))) == [.entityUpsert])
    #expect(types(try await book.ops(of: try #require(result.cardProposal))) == [.milestoneUpsert])
    #expect(result.held == nil)
  }

  // F27 1c: the last staging step records the notes the reply takes, so a turn stopped before it saved the result writes the same reply
  @Test func shouldRecordWithTheLastStagingStepTheNotesTheReplyTakes() async throws {
    let organise = try await StagingWorld.book()
    let workspace = try await StagingWorld.workspace()
    let moved = try await StagingWorld.workspace()
    try await movedHead(3, in: moved)
    let ideas = try await StagingWorld.book()
    let rejected = try #require(try await ideas.turn(try Turn.request(Turn.kael, novel: ideas.novel, mode: .manual, now: ideas.clock.now)).cardProposal)
    _ = try await ideas.store.rejectIdea(proposal: rejected, opIndex: 0, scope: .never, novel: ideas.novel)
    try await ideas.store.write { transaction in try TurnStagingMarks.forget(turn: Turn.reply, in: transaction.database) }
    let held = try await StagingWorld.book()
    let missing = StagingText.rewrite("words that are nowhere in the chapter", "new words")
    let cases: [(ChapterBook, TurnStagingRequest)] = [
      (organise, try Turn.request(Turn.organise, novel: organise.novel, organise: .start, now: organise.clock.now)),
      (workspace, try Turn.request(missing, Turn.removeRise, novel: workspace.novel, now: workspace.clock.now)),
      (moved, try Turn.request(Turn.approve3, Turn.removeRise, novel: moved.novel, now: moved.clock.now)),
      (ideas, try Turn.request(Turn.maraThief, Turn.kael, novel: ideas.novel, now: ideas.clock.now)),
      (held, try Turn.request(Turn.maraThief, Turn.removeRise, novel: held.novel, warnings: [plannerOnlyWarning], now: held.clock.now)),
    ]
    for (index, (book, request)) in cases.enumerated() {
      let result = try await book.turn(request)
      let marks = try #require(try await book.store.read { try TurnStagingMarks.marks(of: Turn.reply, in: $0.database) })
      #expect(marks.last?.notes == result.notes, "case \(index)")
      #expect(result.notes != TurnStagingNotes(), "case \(index) leaves no notes")
    }
  }

  // A step table made before steps carried notes gains the column; its earlier steps read without notes
  @Test func shouldRecordNotesInAStepTableMadeBeforeStepsCarriedThem() async throws {
    let book = try await StagingWorld.book()
    let (earlier, later, card) = (UUID(), UUID(), UUID())
    try await book.store.write { transaction in
      try transaction.database.execute(
        sql: """
          CREATE TABLE nf_local_turn_step (
            turn BLOB NOT NULL, step TEXT NOT NULL, session BLOB NOT NULL, proposal BLOB, cards_follow INTEGER NOT NULL, PRIMARY KEY (turn, step)
          ) STRICT, WITHOUT ROWID
          """)
      try transaction.database.execute(
        sql: "INSERT INTO nf_local_turn_step (turn, step, session, proposal, cards_follow) VALUES (?, 'cards', ?, ?, 0)", arguments: [earlier, StagingWorld.session, card])
    }
    let notes = TurnStagingNotes(applyNote: heldForReviewNote, held: .warnings, replyNote: "Why.")
    try await book.store.write { transaction in
      try TurnStagingMarks.record(.cards(proposal: card), notes: notes, reply: later, session: StagingWorld.session, in: transaction.database)
    }

    let read = try await book.store.read { transaction in
      (try TurnStagingMarks.marks(of: earlier, in: transaction.database), try TurnStagingMarks.marks(of: later, in: transaction.database))
    }
    #expect(read.0 == [TurnStagingMark(step: .cards(proposal: card), notes: nil)])
    #expect(read.1 == [TurnStagingMark(step: .cards(proposal: card), notes: notes)])
  }

  @Test func shouldStageNothingForAnEmptyChangeSet() async throws {
    let book = try await StagingWorld.book()
    let request = TurnStagingRequest(
      novel: book.novel, session: StagingWorld.session, reply: Turn.reply, replyText: "Hi.", changeSet: nil, authorMessage: "Hi.", mode: .auto, justDiscussing: false,
      organise: .none, contexts: [], warnings: [], run: nil, now: book.clock.now)
    #expect(try await book.turn(request) == TurnStagingResult())
    #expect(try await book.proposalCount() == 0)
  }

  @Test func shouldRefuseAChangeSetTheHubDoesNotAllow() async throws {
    let book = try await StagingWorld.book()
    let request = try Turn.request(#"{"op":"nope"}"#, novel: book.novel, now: book.clock.now)
    await #expect(throws: TurnStagingError.self) { try await book.store.stageTurn(request) }
    #expect(try await book.proposalCount() == 0)
  }
}
