import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/classes/app-error-code.ts:168 (RFN_003), the refusal the reference's automatic apply throws on a baseline conflict
let turnApplyConflictNote = "Refinement proposal conflicts with the current artifact state — the artifact changed since the proposal was made"

/// What a chat turn's change set became (turn-proposals.ts:70 with chat-turn-staging.service.ts:55's `replyNote`), as the reply records it.
struct TurnStagingResult: Sendable, Equatable {
  /// The ops that applied in the turn — the author's words and, under Edit freely, the model's ideas — undone by reverting this proposal.
  var appliedProposal: UUID?
  /// One outcome per applied op, each with its write policy source.
  var applied: [ProposalChangeOutcome]?
  /// The suggestions: everything else, pending the author's accept or decline per op.
  var cardProposal: UUID?
  var applyNote: String?
  /// Set when a hold kept ops that would have applied among the cards.
  var held: TurnHoldReason?
  /// Appended to the reply's text.
  var replyNote: String?

  init(
    appliedProposal: UUID? = nil, applied: [ProposalChangeOutcome]? = nil, cardProposal: UUID? = nil, applyNote: String? = nil, held: TurnHoldReason? = nil,
    replyNote: String? = nil
  ) {
    self.appliedProposal = appliedProposal
    self.applied = applied
    self.cardProposal = cardProposal
    self.applyNote = applyNote
    self.held = held
    self.replyNote = replyNote
  }

  var notes: TurnStagingNotes { TurnStagingNotes(applyNote: applyNote, held: held, replyNote: replyNote) }
}

/// How the direct side of a split ended: staged and applied automatically as one step, or left with nothing written.
enum TurnDirectOutcome: Sendable, Equatable {
  case applied(proposal: UUID, changes: [ProposalChangeOutcome])
  /// turn-proposals.ts:146: staged on its own, the direct side raised warnings of its own.
  case warned
  /// turn-proposals.ts:122: why it could not stage or apply, in words the author may read.
  case failed(note: String)
}

struct TurnCardStaging: Sendable, Equatable {
  /// nil when every op was left out on the way.
  let proposal: UUID?
  /// Why ops were left out, for the reply.
  let replyNotes: [String]
}

/// The two steps a turn's split is staged by (turn-proposals.ts:39), each one write transaction, which records the notes the reply takes when no later step
/// commits.
protocol TurnStagingSteps {
  /// `cardsFollow` says whether the split holds cards staged after it, which the applied side records for a turn stopped in between.
  func applyDirect(_ ops: [ChangeOp], sources: [OpSource], entityMaterialization: Bool, cardsFollow: Bool, notes: TurnStagingNotes) async -> TurnDirectOutcome
  func stageCards(
    _ ops: [ChangeOp], warnings: [String], entityMaterialization: Bool, notes: @escaping @Sendable (TurnCardStaging) -> TurnStagingNotes
  ) async throws(TurnStagingError) -> TurnCardStaging
}

enum TurnStagingFlow {
  /// turn-proposals.ts:127: at most two proposals, the applied side first so the cards' baseline includes its records; anything that stops the applied
  /// side turns the whole change set into cards. The direct card is applied or rolled back inside its own step, so no step leaves it pending beside the
  /// cards. A hold note is dropped with a card whose every op was left out. `finish` adds the caller's notes, to the result and to what each step records.
  static func stage(
    _ split: ChangeSetSplit, warnings: [String], steps: some TurnStagingSteps, finish: @escaping @Sendable (TurnStagingResult) -> TurnStagingResult = { $0 }
  ) async throws(TurnStagingError) -> TurnStagingResult {
    guard split.sources.count == split.direct.count else { throw .misalignedSources }
    let hold = turnHoldNote(split.held)
    if split.direct.isEmpty {
      guard !split.cards.isEmpty else { return finish(TurnStagingResult(applyNote: hold?.note, held: hold?.reason)) }
      let settle: @Sendable (TurnCardStaging) -> TurnStagingResult = { finish(held($0, hold: hold)) }
      return settle(try await steps.stageCards(split.cards, warnings: warnings, entityMaterialization: true) { settle($0).notes })
    }

    let half = split.cards.isEmpty
    let alone = finish(TurnStagingResult(applyNote: half ? nil : cardsUnsavedNote)).notes
    switch await steps.applyDirect(split.direct, sources: split.sources, entityMaterialization: half, cardsFollow: !half, notes: alone) {
    case .failed(let note):
      return try await allAsCards(split, warnings: warnings, steps: steps, note: note, held: nil, finish: finish)
    case .warned:
      return try await allAsCards(split, warnings: warnings, steps: steps, note: heldForReviewNote, held: .warnings, finish: finish)
    case .applied(let proposal, let changes):
      let applied = TurnStagingResult(appliedProposal: proposal, applied: changes)
      if half { return finish(applied) }
      let settle: @Sendable (TurnCardStaging) -> TurnStagingResult = { staging in
        let cards = held(staging, hold: hold)
        var result = applied
        result.cardProposal = cards.cardProposal
        result.applyNote = cards.applyNote
        result.held = cards.held
        result.replyNote = cards.replyNote
        return finish(result)
      }
      do throws(TurnStagingError) {
        return settle(try await steps.stageCards(split.cards, warnings: warnings, entityMaterialization: false) { settle($0).notes })
      } catch {
        var result = applied
        result.applyNote = cardsUnsavedNote
        if case .unsaved(_, let notes) = error { result.replyNote = replyNote(notes) }
        return finish(result)
      }
    }
  }

  // turn-proposals.ts:131: staging re-runs its own checks over the whole change set, so a warning the direct side raised comes back on the cards
  private static func allAsCards(
    _ split: ChangeSetSplit, warnings: [String], steps: some TurnStagingSteps, note: String, held: TurnHoldReason?,
    finish: @escaping @Sendable (TurnStagingResult) -> TurnStagingResult
  ) async throws(TurnStagingError) -> TurnStagingResult {
    let settle: @Sendable (TurnCardStaging) -> TurnStagingResult = { cards in
      let staged = cards.proposal != nil
      return finish(TurnStagingResult(cardProposal: cards.proposal, applyNote: staged ? note : nil, held: staged ? held : nil, replyNote: replyNote(cards.replyNotes)))
    }
    return settle(try await steps.stageCards(split.ops, warnings: warnings, entityMaterialization: true) { settle($0).notes })
  }

  private static func held(_ cards: TurnCardStaging, hold: TurnHoldNote?) -> TurnStagingResult {
    let note = cards.proposal == nil ? nil : hold
    return TurnStagingResult(cardProposal: cards.proposal, applyNote: note?.note, held: note?.reason, replyNote: replyNote(cards.replyNotes))
  }

  // chat-turn-staging.service.ts:66
  static func replyNote(_ notes: [String?]) -> String? {
    let kept = notes.compactMap { $0 }.filter { !$0.isEmpty }
    return kept.isEmpty ? nil : kept.joined(separator: "\n\n")
  }

  static func noted(_ result: TurnStagingResult, leading: [String?]) -> TurnStagingResult {
    var result = result
    result.replyNote = replyNote(leading + [result.replyNote])
    return result
  }

  // turn-proposals.ts:122: a refusal's own words, and never the text of a failure of the store
  static func failureNote(_ error: ProposalStagingError) -> String {
    switch error {
    case .store, .unstorable: applyFailedNote
    case .draft(let cause): failureNote(cause)
    case .domain(let cause): failureNote(cause)
    default: error.errorDescription ?? applyFailedNote
    }
  }

  static func failureNote(_ error: ProposalApplyError) -> String {
    switch error {
    case .store, .unstorable, .automaticAction, .automaticAlwaysCard, .sourcesMismatch: applyFailedNote
    case .apply(let cause), .changeRefused(_, let cause), .action(_, let cause): failureNote(cause)
    case .domain(let cause): failureNote(cause)
    default: error.errorDescription ?? applyFailedNote
    }
  }

  static func failureNote(_ error: ApplyError) -> String {
    switch error {
    case .store, .partialWrite: applyFailedNote
    case .domain(let cause): failureNote(cause)
    default: error.errorDescription ?? applyFailedNote
    }
  }

  static func failureNote(_ error: DomainError) -> String {
    if case .store = error { return applyFailedNote }
    return error.errorDescription ?? applyFailedNote
  }
}

enum TurnStagingError: ShadowError, Equatable {
  /// The turn's change set does not validate for the hub (RFN_004).
  case changeSet(ChangeSetError)
  /// turn-proposals.ts:133: a split carries one source per applied op.
  case misalignedSources
  case staging(ProposalStagingError)
  case store(StoreError)
  /// A card that failed after earlier attempts left approvals out, with why each was left out, for the reply.
  indirect case unsaved(TurnStagingError, replyNotes: [String])

  var code: String {
    switch self {
    case .changeSet(let error): error.code
    case .misalignedSources: "refinement.misaligned_sources"
    case .staging(let error): error.code
    case .store(let error): error.code
    case .unsaved(let error, _): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .changeSet(let error): error.errorDescription
    case .misalignedSources: "a split carries one source per applied op"
    case .staging(let error): error.errorDescription
    case .store(let error): error.errorDescription
    case .unsaved(let error, _): error.errorDescription
    }
  }

  static func == (left: TurnStagingError, right: TurnStagingError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}
