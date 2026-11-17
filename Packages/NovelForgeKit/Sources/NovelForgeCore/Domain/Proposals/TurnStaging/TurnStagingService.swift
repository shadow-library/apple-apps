import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/chat-turn-staging.service.ts:24-29, :46-55
struct TurnStagingRequest: Sendable {
  let novel: UUID
  let session: UUID
  /// The reply the turn's proposals belong to, written by the caller once the staging returns.
  let reply: UUID
  /// The reply's text after the turn's guards, whose first line summarises the proposals.
  let replyText: String
  /// The turn's change set after the guards (ProseIntent, LaterPlansGuard).
  let changeSet: [OrderedJSONObject]?
  /// The author's words: their message and their passage comments (`authorWords`).
  let authorMessage: String
  let mode: RefinementChatMode
  let justDiscussing: Bool
  let organise: OrganiseRouting
  let contexts: [ChatPassageContext]
  /// The turn's warnings, the planner-only one included (`chatTurnWarnings`).
  let warnings: [String]
  let run: String?
  let now: Date
}

extension VaultStore {
  /// chat-turn-staging.service.ts:46: validates the turn's change set for the hub, leaves out the rewrites it cannot place, splits the rest by the write
  /// policy over the records as they stand, applies the direct side automatically and stages the rest as one card, each step one write transaction.
  func stageTurn(_ request: TurnStagingRequest) async throws(TurnStagingError) -> TurnStagingResult {
    let proposed: [ChangeOp]
    do throws(ChangeSetError) {
      proposed = try parseOptionalChangeSet(request.changeSet.map { .array($0.map(OrderedJSON.object)) }, allowedOps: hubAllowedOps)
    } catch {
      throw .changeSet(error)
    }
    if proposed.isEmpty { return TurnStagingResult() }

    let plan = try await turnWrite { transaction throws(TurnStagingError) in try TurnStagingPlan.make(request, ops: proposed, in: transaction) }
    let steps = TurnStoreSteps(store: self, request: request)
    var result: TurnStagingResult
    var organiseNote: String?
    switch plan.route {
    case .empty:
      result = TurnStagingResult()
    case .organise(let ops):
      let card = try await steps.stageCards(ops, warnings: request.warnings, entityMaterialization: true)
      organiseNote = card.proposal == nil ? nil : TurnStagingPlan.organiseWaitsNote()
      result = TurnStagingResult(cardProposal: card.proposal, replyNote: TurnStagingFlow.replyNote(card.replyNotes))
    case .split(let turn) where turn.split.ops.isEmpty:
      result = TurnStagingResult(applyNote: ideasDroppedNote)
    case .split(let turn):
      result = try await TurnStagingFlow.stage(turn.split, warnings: request.warnings, steps: steps)
      // chat-turn-staging.service.ts:146
      if !turn.droppedIdeas.isEmpty { result.applyNote = [result.applyNote, ideasDroppedNote].compactMap { $0 }.joined(separator: " ") }
    }
    result.replyNote = TurnStagingFlow.replyNote([organiseNote, TurnRewriteAnchoring.droppedNote(plan.droppedRewrites), result.replyNote])
    return result
  }

  fileprivate func turnWrite<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(TurnStagingError) -> T) async throws(TurnStagingError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let staging = cause as? TurnStagingError { throw staging }
      throw .store(error)
    }
  }
}

struct TurnStagingPlan: Sendable {
  enum Route: Sendable {
    case empty
    /// chat-turn-staging.service.ts:110: the author asked to organise their notes and the turn holds that action alone.
    case organise([ChangeOp])
    case split(TurnSplit)
  }

  let route: Route
  let droppedRewrites: [DroppedRewrite]

  /// chat-turn-staging.service.ts:56-65, :110-129 over this transaction, which writes nothing.
  static func make(_ request: TurnStagingRequest, ops: [ChangeOp], in transaction: borrowing WriteTransaction) throws(TurnStagingError) -> TurnStagingPlan {
    let anchored = try anchored(ops, request: request, in: transaction)
    let kept = anchored.ops
    if kept.isEmpty { return TurnStagingPlan(route: .empty, droppedRewrites: anchored.dropped) }
    if request.organise == .start, kept.count == 1, kept[0].type == .actionOrganiseNotes, turnHold(request.warnings) != .turn {
      return TurnStagingPlan(route: .organise(kept), droppedRewrites: anchored.dropped)
    }

    let refs = changeSetRefs(kept)
    let current: CurrentRecords
    let referenced: [JSString: ArtifactState]
    do throws(StoreError) {
      current = try ArtifactStateLoader.currentRecords(refs: refs, novel: request.novel, in: transaction)
      referenced = try ArtifactStateLoader.states(refs: kept.flatMap(opReferences).jsUnique(), novel: request.novel, in: transaction)
    } catch {
      throw .store(error)
    }
    let unreadable = current.unreadable.union(referenced.filter(\.value.isUnreadable).keys)
    let state = WritePolicyState(current: refs.compactMap { ref in current[ref]?.fields.map { (ref: ref, fields: $0) } }, unreadable: unreadable)
    let context = TurnPolicyContext(authorMessage: request.authorMessage, mode: request.mode, justDiscussing: request.justDiscussing, warnings: request.warnings)
    let split = splitTurnChangeSet(kept, context: context, state: state) { ideaIds in rejectedIdeas(ideaIds, novel: request.novel, in: transaction) }
    return TurnStagingPlan(route: .split(split), droppedRewrites: anchored.dropped)
  }

  /// turn-proposals.ts:176 for the refusal this version gives: no device runs the organise job before the chapter pipelines, so the card waits for the author.
  static func organiseWaitsNote() -> String {
    guard ProposalActionRegistry.executor(for: .actionOrganiseNotes) == nil else { return organiseRefusedNote }
    let message = ApplyError.notYetAvailable(.actionOrganiseNotes).errorDescription ?? ""
    return "\(organiseRefusedNote) \(message.jsReplace(sentenceEnd, "."))"
  }

  // turn-proposals.ts:179
  private static let sentenceEnd = ProseRegex.literal(#"\.?$"#)

  // passage-rewrite.ts:126 (loadChapters) through this device's working copies, as staging reads them; a draft it cannot read leaves its rewrites out
  private static func anchored(_ ops: [ChangeOp], request: TurnStagingRequest, in transaction: borrowing WriteTransaction) throws(TurnStagingError) -> AnchoredRewrites {
    var drafts = [Int: AnchorDraft]()
    var unreadable = Set<Int>()
    for chapter in PassageAnchoring.rewriteChapters(ops) {
      do throws(ProposalStagingError) {
        drafts.merge(try ProposalStamps.rewriteDrafts([chapter], novel: request.novel, in: transaction)) { _, read in read }
      } catch {
        guard case .draft(.unreadable) = error else { throw .staging(error) }
        unreadable.insert(chapter)
      }
    }
    return TurnRewriteAnchoring.anchor(ops, drafts: drafts, unreadable: unreadable, contexts: request.contexts)
  }

  /// idea-rejections.ts:67 (loadRejectedIdeas). Anything this device cannot read — a Notebook entry, a rejection scope or anchor it does not know, a volume,
  /// a record a rejection is anchored to — fails the read, so every idea stays a card (turn-proposals.ts:108).
  static func rejectedIdeas(_ ideaIds: [String], novel: UUID, in transaction: borrowing WriteTransaction) -> Set<JSString>? {
    do throws(StoreError) {
      let ledger = try NotebookLedger.load(novel: novel, in: transaction)
      guard ledger.unreadable == 0 else { return nil }
      let wanted = Set(ideaIds.map { JSString($0) })
      let records = ledger.active().map(\.record).filter { record in record.idea.map { wanted.contains(JSString($0)) } ?? false }
      let entries = records.map(ChatContextLedger.rejection)
      let unknown = zip(records, entries).contains { record, entry in
        (record.rejectionScope != nil && entry.rejectionScope == nil) || (record.rejectionAnchor.map { $0 != .null } == true && entry.rejectionAnchor == nil)
      }
      if unknown { return nil }
      if entries.isEmpty { return [] }
      let volumes = try VolumeRecord.listing(novel: novel, in: transaction)
      guard volumes.unreadable == 0 else { return nil }
      let states = try ArtifactStateLoader.states(refs: rejectionStateRefs(for: entries), novel: novel, in: transaction)
      guard !states.values.contains(where: \.isUnreadable) else { return nil }
      let standings = volumeStandings(of: volumes.live).map { RejectionVolume(volumeKey: $0.volume, ordinal: $0.ordinal, state: $0.state) }
      return activeRejectedIdeas(ideaIds, entries: entries, volumes: standings, artifactStates: states)
    } catch {
      return nil
    }
  }
}

/// The store's two steps, each one write transaction: the direct card staged and applied together, or rolled back whole; the cards staged once the direct
/// card is settled, so no transaction leaves two pending cards that may overlap.
struct TurnStoreSteps: TurnStagingSteps {
  private struct DirectAbort: Error {
    let outcome: TurnDirectOutcome
  }

  let store: VaultStore
  let request: TurnStagingRequest

  // turn-proposals.ts:141-157 in one transaction: a direct card that cannot stage, raises warnings of its own or does not apply is never written
  func applyDirect(_ ops: [ChangeOp], sources: [OpSource], entityMaterialization: Bool) async -> TurnDirectOutcome {
    let request = request
    do {
      return try await store.write { transaction in
        let staged: StagedProposal
        do throws(TurnStagingError) {
          staged = try Self.stage(ops, warnings: [], entityMaterialization: entityMaterialization, request: request, in: &transaction)
        } catch {
          throw DirectAbort(outcome: .failed(note: Self.failureNote(error)))
        }
        guard staged.proposal.card.warnings.isEmpty else { throw DirectAbort(outcome: .warned) }
        let context = ProposalApplyContext(novel: request.novel, now: request.now, automatic: true, sources: sources)
        let outcome: ProposalApplyOutcome
        do throws(ProposalApplyError) {
          outcome = try ProposalApply.apply(proposal: staged.proposal.id, selection: .whole, context: context, in: &transaction)
        } catch {
          throw DirectAbort(outcome: .failed(note: TurnStagingFlow.failureNote(error)))
        }
        switch outcome {
        case .conflicted: throw DirectAbort(outcome: .failed(note: turnApplyConflictNote))
        case .applied(let changes): return .applied(proposal: staged.proposal.id, changes: changes)
        }
      }
    } catch {
      if case .aborted(let cause) = error, let abort = cause as? DirectAbort { return abort.outcome }
      return .failed(note: applyFailedNote)
    }
  }

  /// turn-proposals.ts:136, :168 and :131. An approval over a working copy that rests on an earlier head refuses the whole staging, so the staging runs
  /// again without that chapter's approvals and the reply says why; it never turns the rest into something else.
  func stageCards(_ ops: [ChangeOp], warnings: [String], entityMaterialization: Bool) async throws(TurnStagingError) -> TurnCardStaging {
    var remaining = ops
    var notes = [String]()
    let request = request
    while !remaining.isEmpty {
      let attempt = remaining
      do throws(TurnStagingError) {
        let proposal = try await store.turnWrite { transaction throws(TurnStagingError) in
          try Self.stage(attempt, warnings: warnings, entityMaterialization: entityMaterialization, request: request, in: &transaction).proposal.id
        }
        return TurnCardStaging(proposal: proposal, replyNotes: notes)
      } catch {
        guard case .staging(.approvalOverMovedDraft(let chapter)) = error else { throw notes.isEmpty ? error : .unsaved(error, replyNotes: notes) }
        remaining = attempt.filter { op in
          guard case .actionApproveDraft(let approval) = op.operation else { return true }
          return approval.chapter != chapter
        }
        guard remaining.count < attempt.count else { throw error }
        notes.append(error.errorDescription ?? "")
      }
    }
    return TurnCardStaging(proposal: nil, replyNotes: notes)
  }

  // chat-turn-staging.service.ts:90-104: the stager does not check allowed ops, so the change set is validated for the hub here
  private static func stage(
    _ ops: [ChangeOp], warnings: [String], entityMaterialization: Bool, request: TurnStagingRequest, in transaction: inout WriteTransaction
  ) throws(TurnStagingError) -> StagedProposal {
    let changeSet: ValidatedChangeSet
    do throws(ChangeSetError) {
      changeSet = try ValidatedChangeSet(
        .array(ops.map { .object($0.fields) }), allowedOps: hubAllowedOps, options: ChangeSetValidationOptions(entityMaterialization: entityMaterialization))
    } catch {
      throw .changeSet(error)
    }
    let summary = request.replyText.jsSplit("\n", limit: 1).first?.jsSlice(0, 300)
    let input = ProposalStagingInput(
      novel: request.novel, session: request.session, message: request.reply, kind: .hub, summary: summary, changeSet: changeSet, run: request.run, warnings: warnings)
    do throws(ProposalStagingError) {
      return try ProposalStager.stage(input, in: &transaction)
    } catch {
      throw .staging(error)
    }
  }

  private static func failureNote(_ error: TurnStagingError) -> String {
    switch error {
    case .staging(let cause): TurnStagingFlow.failureNote(cause)
    case .store, .misalignedSources: applyFailedNote
    case .changeSet: error.errorDescription ?? applyFailedNote
    case .unsaved(let cause, _): failureNote(cause)
    }
  }
}
