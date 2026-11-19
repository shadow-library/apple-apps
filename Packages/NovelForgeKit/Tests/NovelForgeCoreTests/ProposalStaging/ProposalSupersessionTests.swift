import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias Text = StagingText
private typealias World = StagingWorld

private let maraEdit = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","notes":"Left-handed."}"#

// apps/novel-forge-server/src/modules/refinement/proposal.service.ts:214-234; apps/novel-forge-server/tests/refinement/passage-rewrite.spec.ts:347-386
@Suite("Proposal supersession", TestTimeLimit.standard)
struct ProposalSupersessionTests {
  @Test func shouldKeepAnEarlierCardThatRewritesAnotherPassageOfTheSameChapter() async throws {
    let book = try await World.workspace()
    let first = try await book.stage(Text.rewrite(Text.wrist, Text.wristRewrite))
    let second = try await book.stage(Text.rewrite(Text.fear, Text.fearRewrite))
    #expect(try await book.decision(first.proposal.id) == .known(.pending))
    #expect(second.superseded.isEmpty && second.proposal.card.supersedes.isEmpty)
  }

  @Test func shouldReplaceAnEarlierCardThatRewritesTheSameWordsInTheSameTransaction() async throws {
    let book = try await World.workspace()
    let first = try await book.stage(Text.rewrite(Text.wrist, Text.wristRewrite))
    let second = try await book.stage(Text.rewrite("his right hand", "his wrist"))
    #expect(try await book.decision(first.proposal.id) == .known(.superseded))
    #expect(second.superseded == [first.proposal.id])
    #expect(try await book.proposal(second.proposal.id).card.supersedes == [first.proposal.id])
    let state = try #require(try await Projection.fetch(ProposalStateDerivation.request(for: first.proposal.ref), in: book.store).first)
    #expect(state.decision == .known(.superseded))
  }

  @Test func shouldReplaceAnEarlierCardWhosePassageNoLongerStands() async throws {
    let book = try await World.workspace()
    let first = try await book.stage(Text.rewrite(Text.wrist, Text.wristRewrite))
    let edited = Text.body.replacingOccurrences(of: "knuckles stopped", with: "knuckles finally stopped")
    try await book.save(3, edited, summary: "It turns.", base: nil)
    _ = try await book.stage(Text.rewrite(Text.fear, Text.fearRewrite))
    #expect(try await book.decision(first.proposal.id) == .known(.superseded))
  }

  @Test func shouldReplaceARewriteCardWithAWholeChapterEditAndAWholeChapterCardWithARewrite() async throws {
    let book = try await World.workspace()
    let rewriteCard = try await book.stage(Text.rewrite(Text.wrist, Text.wristRewrite))
    let wholeCard = try await book.stage(#"{"op":"draft.update","chapter":3,"title":"The Second Bout"}"#)
    #expect(try await book.decision(rewriteCard.proposal.id) == .known(.superseded))
    _ = try await book.stage(Text.rewrite(Text.fear, Text.fearRewrite))
    #expect(try await book.decision(wholeCard.proposal.id) == .known(.superseded))
  }

  // proposal.service.ts:226: one action decision supersedes another of the same key
  @Test func shouldReplaceAnEarlierCardThatTakesTheSameActionDecision() async throws {
    let book = try await World.workspace()
    let first = try await book.stage(#"{"op":"action.approve_draft","chapter":3}"#)
    let other = try await book.stage(#"{"op":"action.approve_draft","chapter":4}"#)
    _ = try await book.stage(#"{"op":"action.approve_draft","chapter":3}"#, maraEdit)
    #expect(try await book.decision(first.proposal.id) == .known(.superseded))
    #expect(try await book.decision(other.proposal.id) == .known(.pending))
  }

  // proposal.service.ts:81-88: only the session's own chat-staged cards are replaced
  @Test func shouldLeaveOtherSessionsCardsBroughtInCardsAndSessionlessCardsStanding() async throws {
    let book = try await World.book()
    let otherSession = try await book.stage(maraEdit, session: World.otherSession)
    let audit = try await book.stage(maraEdit, kind: .bibleAudit)
    let sessionless = try await book.stage(maraEdit, session: nil)
    let chat = try await book.stage(maraEdit, kind: .chat)
    let replacing = try await book.stage(maraEdit, kind: .organise)
    #expect(replacing.superseded == [chat.proposal.id])
    for kept in [otherSession, audit, sessionless] { #expect(try await book.decision(kept.proposal.id) == .known(.pending)) }
    _ = try await book.stage(maraEdit, session: nil)
    #expect(try await book.decision(sessionless.proposal.id) == .known(.pending))
  }

  // The decision is the source of truth: a card already settled is never raised again or listed
  @Test func shouldReplaceOnlyCardsWhoseDecisionIsStillPending() async throws {
    let book = try await World.book()
    let discarded = try await book.stage(maraEdit)
    try await book.run { try ProposalDiscard.discard(discarded.proposal.id, novel: book.novel, in: &$0) }
    let applied = try await book.stage(#"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","status":"alive"}"#)
    try await book.setDecision(applied.proposal.id, ProposalDecision.applied.rawValue)
    let newest = try await book.stage(maraEdit)
    #expect(newest.superseded.isEmpty)
    #expect(try await book.decision(discarded.proposal.id) == .known(.discarded))
    #expect(try await book.decision(applied.proposal.id) == .known(.applied))
  }

  // Without the chat derivation the session's cards are read from the records
  @Test func shouldFindTheSessionsPendingCardsWithoutTheChatDerivation() async throws {
    let book = try await ChapterBook.make()
    let other = try await book.stage(maraEdit, session: World.otherSession)
    let first = try await book.stage(maraEdit)
    let second = try await book.stage(maraEdit)
    #expect(second.superseded == [first.proposal.id])
    #expect(try await book.decision(first.proposal.id) == .known(.superseded))
    #expect(try await book.decision(other.proposal.id) == .known(.pending))
  }

  // A card whose derived row is faulted is still found: by its fault key, or by every proposal while the derivation is faulted whole
  @Test(arguments: [false, true])
  func shouldFindAPendingCardTheChatDerivationHoldsFaulted(whole: Bool) async throws {
    let book = try await World.book()
    let first = try await book.stage(maraEdit)
    let key = whole ? ProjectionFaults.wholeDerivation : ProjectionFaults.key(first.proposal.ref)
    _ = try await book.store.write { transaction in
      try transaction.database.execute(sql: "DELETE FROM \(ProposalState.databaseTableName) WHERE proposal = ?", arguments: [first.proposal.id])
      try transaction.database.execute(
        sql: "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'probe')",
        arguments: [ProposalState.databaseTableName, key])
    }
    let input = World.input(try World.changeSet(maraEdit), novel: book.novel)
    let second = try await book.store.write { try ProposalStager.stage(input, in: &$0) }
    #expect(second.superseded == [first.proposal.id])
    #expect(try await book.decision(first.proposal.id) == .known(.superseded))
  }

  // The derivation is reconciled at commit: within one transaction, a card discarded is no longer pending, and one staged earlier is
  @Test func shouldJudgeCardsByTheDecisionTheyHoldInThisTransaction() async throws {
    let book = try await World.book()
    let novel = book.novel
    let changeSet = try World.changeSet(maraEdit)
    let discarded = try await book.stage(maraEdit)
    let (first, second) = try await book.run { transaction in
      try ProposalDiscard.discard(discarded.proposal.id, novel: novel, in: &transaction)
      let first = try ProposalStager.stage(World.input(changeSet, novel: novel), in: &transaction)
      let second = try ProposalStager.stage(World.input(changeSet, novel: novel), in: &transaction)
      return (first, second)
    }
    #expect(first.superseded.isEmpty)
    #expect(second.superseded == [first.proposal.id])
    #expect(try await book.decision(discarded.proposal.id) == .known(.discarded))
    #expect(try await book.decision(first.proposal.id) == .known(.superseded))
  }
}

// proposal.service.ts:72, :398-409; apps/novel-forge-server/tests/refinement/proposal-discard.spec.ts
@Suite("Proposal discard", TestTimeLimit.standard)
struct ProposalDiscardTests {
  @Test func shouldDiscardAPendingCard() async throws {
    let book = try await World.book()
    let staged = try await book.stage(maraEdit)
    try await book.store.discardProposal(staged.proposal.id, novel: book.novel)
    #expect(try await book.decision(staged.proposal.id) == .known(.discarded))
  }

  @Test func shouldRefuseASupersededDiscardedOrAppliedCardAndLeaveItsDecision() async throws {
    let book = try await World.book()
    let superseded = try await book.stage(maraEdit)
    _ = try await book.stage(maraEdit)
    let applied = try await book.stage(maraEdit, session: World.otherSession)
    try await book.setDecision(applied.proposal.id, ProposalDecision.applied.rawValue)
    let discarded = try await book.stage(maraEdit, session: nil)
    try await book.store.discardProposal(discarded.proposal.id, novel: book.novel)
    let cases: [(UUID, StoredEnum<ProposalDecision>)] = [
      (superseded.proposal.id, .known(.superseded)), (applied.proposal.id, .known(.applied)), (discarded.proposal.id, .known(.discarded)),
    ]
    for (id, decision) in cases {
      await #expect(throws: ProposalDecisionError.notPending(decision)) { try await book.store.discardProposal(id, novel: book.novel) }
      #expect(try await book.decision(id) == decision)
    }
  }

  @Test func shouldRefuseAProposalTheNovelDoesNotHold() async throws {
    let book = try await World.book()
    let staged = try await book.stage(maraEdit)
    let missing = UUID()
    await #expect(throws: ProposalDecisionError.notFound(missing)) { try await book.store.discardProposal(missing, novel: book.novel) }
    await #expect(throws: ProposalDecisionError.notFound(staged.proposal.id)) {
      try await book.store.discardProposal(staged.proposal.id, novel: SchemaFixture.otherNovel)
    }
  }

  // A card a newer version wrote is still set aside by its stored decision and novel
  @Test func shouldDiscardAPendingCardThisDeviceCannotRead() async throws {
    let book = try await World.book()
    let staged = try await book.stage(maraEdit)
    let card: JSONValue = ["novel": book.novel.json, "kind": "chat", "changeSet": .int(1)]
    let unreadable = UUID()
    try await book.run { transaction in
      _ = try transaction.set(ProposalRecord.ref(id: unreadable), [ProposalField.card.rawValue: card, ProposalField.decision.rawValue: .string("pending")])
    }
    #expect(try await book.store.read { try ProposalRecord.read(id: unreadable, in: $0) }.entry == nil)
    try await book.store.discardProposal(unreadable, novel: book.novel)
    let decision = try await book.store.read { transaction in
      try transaction.state(of: ProposalRecord.ref(id: unreadable), scope: .vault).flatMap { ProposalSnapshot(ProposalRecord.ref(id: unreadable), $0)?.decision }
    }
    #expect(decision == .known(.discarded))
    #expect(try await book.decision(staged.proposal.id) == .known(.pending))
  }
}
