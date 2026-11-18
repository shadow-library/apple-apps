import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private func changeOps(_ ops: String...) throws -> [ChangeOp] {
  try parseChangeSet(try OrderedJSON(parsing: "[\(ops.joined(separator: ","))]"), options: ChangeSetValidationOptions(entityMaterialization: false))
}

private final class FailingCards: TurnStagingSteps {
  private(set) var calls = 0

  func applyDirect(_ ops: [ChangeOp], sources: [OpSource], entityMaterialization: Bool, cardsFollow: Bool, notes: TurnStagingNotes) async -> TurnDirectOutcome {
    calls += 1
    return .applied(proposal: UUID(), changes: [])
  }

  func stageCards(
    _ ops: [ChangeOp], warnings: [String], entityMaterialization: Bool, notes: @escaping @Sendable (TurnCardStaging) -> TurnStagingNotes
  ) async throws(TurnStagingError) -> TurnCardStaging {
    calls += 1
    throw .store(.invalidChange("disk full"))
  }
}

private final class EmptiedCards: TurnStagingSteps {
  let direct: TurnDirectOutcome?
  let failure: TurnStagingError?

  init(direct: TurnDirectOutcome? = nil, failure: TurnStagingError? = nil) {
    self.direct = direct
    self.failure = failure
  }

  func applyDirect(_ ops: [ChangeOp], sources: [OpSource], entityMaterialization: Bool, cardsFollow: Bool, notes: TurnStagingNotes) async -> TurnDirectOutcome {
    direct ?? .failed(note: applyFailedNote)
  }

  func stageCards(
    _ ops: [ChangeOp], warnings: [String], entityMaterialization: Bool, notes: @escaping @Sendable (TurnCardStaging) -> TurnStagingNotes
  ) async throws(TurnStagingError) -> TurnCardStaging {
    if let failure { throw failure }
    return TurnCardStaging(proposal: nil, replyNotes: ["Chapter 3 moved."])
  }
}

@Suite("Turn staging policy")
struct TurnStagingPolicyTests {
  // State file, F11a rule 6: an unreadable ref exists for every rule that asks, and an op that writes or names it waits for the author
  @Test func shouldHoldAnOpOnAnUnreadableRecordWithoutCountingItAsCreated() throws {
    let message = "Ghost is a thief who works the Saltgate docks."
    let ops = try changeOps(
      #"{"op":"entity.upsert","entityKey":"ghost","type":"character","name":"Ghost","status":"thief","quote":"Ghost is a thief who works the Saltgate docks"}"#,
      #"{"op":"milestone.upsert","milestoneKey":"heist","label":"The heist","subjectEntityKey":"ghost"}"#)
    let state = WritePolicyState(unreadable: ["entity:ghost"])
    let split = WritePolicy.split(WritePolicyInput(ops: ops, authorMessage: message, mode: .auto, ideas: .apply, hold: .none, state: state))

    #expect(state.has("entity:ghost"))
    #expect(split.dispositions == [.card(index: 0, reason: .heldForReview, rule: nil), .card(index: 1, reason: .notAllowlisted, rule: nil)])
    #expect(split.held == .none)
    let readable = WritePolicy.split(WritePolicyInput(ops: ops, authorMessage: message, mode: .auto, ideas: .apply, hold: .none, state: WritePolicyState()))
    #expect(readable.dispositions == [.direct(index: 0, source: .quoted), .direct(index: 1, source: .idea)])
  }

  @Test func shouldLeaveOutARewriteOfADraftThisDeviceCannotRead() throws {
    let ops = try changeOps(#"{"op":"draft.rewrite_passage","chapter":4,"passage":"the lamp","replacement":"the lantern","label":"lamp"}"#)
    let anchored = TurnRewriteAnchoring.anchor(ops, drafts: [:], unreadable: [4], contexts: [])

    #expect(anchored.ops.isEmpty)
    #expect(anchored.dropped == [DroppedRewrite(chapter: 4, label: "lamp", reason: .unreadable)])
    #expect(TurnRewriteAnchoring.droppedNote(anchored.dropped) == "Forge left out a passage rewrite:\n- “lamp” in chapter 4: its draft cannot be read on this device.")
  }

  // turn-proposals.spec.ts:192
  @Test func shouldNeverShowTheAuthorTheTextOfAFailureOfTheStore() {
    #expect(TurnStagingFlow.failureNote(ProposalStagingError.store(.invalidChange("disk full at /var/db"))) == applyFailedNote)
    #expect(TurnStagingFlow.failureNote(ProposalApplyError.apply(.domain(.store(.invalidChange("disk full"))))) == applyFailedNote)
    #expect(TurnStagingFlow.failureNote(ProposalApplyError.changeRefused(indexes: [0], .partialWrite(ref: "entity:mara"))) == applyFailedNote)
    #expect(TurnStagingFlow.failureNote(ProposalApplyError.changeRefused(indexes: [0], .refused(.locked))) == ApplyRefusal.locked.errorDescription)
    #expect(TurnStagingFlow.failureNote(ProposalStagingError.notAllowed(problems: ["x"])).hasPrefix("Change-set operation not allowed for this scope"))
  }

  // turn-proposals.spec.ts:163
  @Test func shouldRefuseASplitWhoseSourcesAreMisalignedBeforeStagingAnything() async throws {
    let ops = try changeOps(#"{"op":"milestone.upsert","milestoneKey":"heist","label":"The heist"}"#)
    let split = ChangeSetSplit(ops: ops, direct: ops, cards: [], sources: [], dispositions: [.direct(index: 0, source: .idea)], held: .none)
    let steps = FailingCards()

    await #expect(throws: TurnStagingError.misalignedSources) { try await TurnStagingFlow.stage(split, warnings: [], steps: steps) }
    #expect(steps.calls == 0)
  }

  // turn-proposals.spec.ts:207
  @Test func shouldKeepTheAppliedChangeWhenTheCardsCannotBeSavedAfterIt() async throws {
    let ops = try changeOps(
      #"{"op":"milestone.upsert","milestoneKey":"heist","label":"The heist"}"#, #"{"op":"milestone.remove","milestoneKey":"rise"}"#)
    let split = ChangeSetSplit(
      ops: ops, direct: [ops[0]], cards: [ops[1]], sources: [.idea], dispositions: [.direct(index: 0, source: .idea), .card(index: 1, reason: .alwaysCard, rule: .removal)],
      held: .writerRead)
    let result = try await TurnStagingFlow.stage(split, warnings: [plannerOnlyWarning], steps: FailingCards())

    #expect(result.appliedProposal != nil && result.cardProposal == nil)
    #expect(result.applyNote == cardsUnsavedNote && result.held == nil)
  }

  @Test func shouldDropTheHoldNoteWithACardWhoseEveryOpWasLeftOut() async throws {
    let ops = try changeOps(
      #"{"op":"milestone.upsert","milestoneKey":"heist","label":"The heist"}"#, #"{"op":"action.approve_draft","chapter":3}"#)
    let cardsOnly = ChangeSetSplit(ops: [ops[1]], direct: [], cards: [ops[1]], sources: [], dispositions: [.card(index: 0, reason: .heldForReview, rule: nil)], held: .turn)
    let warned = ChangeSetSplit(
      ops: ops, direct: [ops[0]], cards: [ops[1]], sources: [.idea], dispositions: [.direct(index: 0, source: .idea), .card(index: 1, reason: .alwaysCard, rule: .action)],
      held: .none)

    for result in [
      try await TurnStagingFlow.stage(cardsOnly, warnings: ["echo"], steps: EmptiedCards()),
      try await TurnStagingFlow.stage(warned, warnings: [], steps: EmptiedCards(direct: .warned)),
    ] {
      #expect(result == TurnStagingResult(replyNote: "Chapter 3 moved."))
    }
  }

  @Test func shouldCarryWhyApprovalsWereLeftOutWhenTheCardsCannotBeSavedAfterTheApply() async throws {
    let ops = try changeOps(
      #"{"op":"milestone.upsert","milestoneKey":"heist","label":"The heist"}"#, #"{"op":"milestone.remove","milestoneKey":"rise"}"#)
    let split = ChangeSetSplit(
      ops: ops, direct: [ops[0]], cards: [ops[1]], sources: [.idea], dispositions: [.direct(index: 0, source: .idea), .card(index: 1, reason: .alwaysCard, rule: .removal)],
      held: .none)
    let failure = TurnStagingError.unsaved(.store(.invalidChange("disk full")), replyNotes: ["Chapter 3 moved."])
    let result = try await TurnStagingFlow.stage(split, warnings: [], steps: EmptiedCards(direct: .applied(proposal: UUID(), changes: []), failure: failure))

    #expect(result.applyNote == cardsUnsavedNote && result.replyNote == "Chapter 3 moved." && result.cardProposal == nil)
  }

  @Test func shouldJoinTheReplyNotesWithABlankLineSkippingEmptyOnes() {
    #expect(TurnStagingFlow.replyNote([nil, "a", "", "b"]) == "a\n\nb")
    #expect(TurnStagingFlow.replyNote([nil, ""]) == nil)
  }
}
