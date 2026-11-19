import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs

/// Where the finalize review stands (apps/novel-forge-web/src/lib/finalize-review.ts:116-153): the read first, then the answers, then what else readiness
/// refuses. Native finalize always goes through a read (decision 2), so a chapter with none has no Finalize, only Approve.
struct FinalizePresentation: Equatable {
  enum Phase: Equatable {
    case noDraft
    case unavailable(FinalizeReviewScreen.Unavailable)
    case unreviewed
    case preparing
    case failed(AttemptFailure?)
    case invalidated
    case answering(open: Int)
    case answered
    case finalizable
    case applied
  }

  struct Detail: Equatable {
    let label: String
    let value: String
  }

  struct Update: Equatable {
    let category: String
    let claim: String?
    let details: [Detail]
  }

  struct OtherSet: Equatable {
    /// Nil when this device cannot list what the other finalize kept.
    let updates: [Update]?
    let exact: Bool
  }

  /// Another device's finalize named other updates than the canon applied: the applied set stands, and both are listed for the author to check.
  struct TwoSets: Equatable {
    /// The losing finalizes, so acknowledging the notice holds until another one arrives.
    let id: String
    let applied: [Update]
    let others: [OtherSet]
  }

  // FinalizeReviewDialog.tsx:49
  static let stuckAfter = Duration.seconds(60)

  let phase: Phase
  let review: FinalizeReviewScreen.Review?
  let consequential: [FinalizeReviewScreen.Item]
  let routine: [FinalizeReviewScreen.Item]
  let autoKeep: [FinalizeCategory]
  /// Readiness' refusals in its order, minus the open-answers count the dialog shows item by item (finalize-review.ts:150-153).
  let blockers: [String]
  let readinessUnavailable: Bool
  let isolated: Bool
  let twoSets: TwoSets?

  init(screen: FinalizeReviewScreen, readiness: FinalizeReadiness?) {
    self.init(screen: screen, blockers: readiness?.blockers)
  }

  init(screen: FinalizeReviewScreen, blockers readiness: Derived<[FinalizeBlocker]>?) {
    isolated = screen.isolated
    autoKeep = screen.autoKeep
    var review: FinalizeReviewScreen.Review?
    var twoSets: TwoSets?
    switch screen.state {
    case .noDraft: phase = .noDraft
    case .unavailable(let reason): phase = .unavailable(reason)
    case .unreviewed: phase = .unreviewed
    case .preparing: phase = .preparing
    case .failed(_, let failure): phase = .failed(failure)
    case .invalidated: phase = .invalidated
    case .ready(let ready):
      review = ready
      let open = ready.items.filter { $0.decision == nil }.count
      phase = open > 0 ? .answering(open: open) : readiness == .available([]) ? .finalizable : .answered
    case .applied(let applied):
      review = applied.review
      phase = .applied
      if !applied.otherSets.isEmpty {
        twoSets = TwoSets(
          id: applied.otherSets.map(\.id).sorted().joined(separator: " "), applied: applied.kept.map(Self.update),
          others: applied.otherSets.map { OtherSet(updates: $0.updates?.map(Self.update), exact: $0.exact) })
      }
    }
    self.review = review
    self.twoSets = twoSets
    consequential = review?.items.filter { $0.triage == .consequential } ?? []
    routine = review?.items.filter { $0.triage == .routine } ?? []
    let gated: Bool
    switch phase {
    case .unreviewed, .answering, .answered, .finalizable: gated = true
    case .noDraft, .unavailable, .preparing, .failed, .invalidated, .applied: gated = false
    }
    let refusals = gated ? readiness?.value ?? [] : []
    blockers = refusals.filter { if case .unanswered = $0 { false } else { true } }.map(FinalizeErrors.headline(for:))
    readinessUnavailable = gated && readiness?.isUnavailable == true
  }

  var openConsequential: Int { consequential.filter { $0.decision == nil }.count }
  var openRoutine: Int { routine.filter { $0.decision == nil }.count }
  var reopened: Int { (review?.items ?? []).filter(\.reopened).count }

  // finalize-review.ts:284-286
  var kept: Int { (review?.items ?? []).filter { $0.decision == .kept || $0.decision == .edited }.count }

  var isReviewing: Bool {
    switch phase {
    case .answering, .answered, .finalizable: true
    default: false
    }
  }

  /// finalize-review.ts:142-147: offered while the read is answered or being answered, enabled only once nothing blocks.
  var offersFinalize: Bool { isReviewing }
  var canFinalize: Bool { phase == .finalizable }

  /// The dialog's Finalize also waits for an answer in flight and for an open form (FinalizeReviewDialog.tsx:484).
  func finalizeEnabled(deciding: Bool, finalizing: Bool, formOpen: Bool) -> Bool {
    canFinalize && !deciding && !finalizing && !formOpen
  }

  /// FinalizeReviewDialog.tsx:258-277: a failed read is read again at once, a read still preparing once it seems stuck.
  func offersReadAgain(stuck: Bool) -> Bool {
    switch phase {
    case .failed: true
    case .preparing: stuck
    default: false
    }
  }

  /// Approval finalizes a standard chapter on its own once its read leaves nothing to ask; an isolated one waits for its author (decision 12).
  var finalizesOnItsOwn: Bool { !isolated }

  /// Why the review can't be read now, in the author's terms: a record from a newer version needs the app updated.
  var unavailableMessage: String? {
    switch phase {
    case .unavailable(.unreadable):
      String(localized: "Part of this chapter's Story Bible review is stored in a form this version of Novel Forge can't read. You may need to update the app.", table: "Finalize")
    case .unavailable(.rebuilding): String(localized: "This chapter's jobs are being rebuilt on this device. Try again in a moment.", table: "Finalize")
    default: readinessUnavailable ? String(localized: "This chapter's Story Bible review can't be read on this device right now.", table: "Finalize") : nil
    }
  }

  var autoKeepChoices: [FinalizeCategory] { FinalizeReviewDisplay.autoKeepChoices(routine: routine, autoKeep: autoKeep) }

  private static func update(_ update: FinalizeReviewScreen.Update) -> Update {
    Update(
      category: FinalizeReviewDisplay.category(update.category), claim: update.claim,
      details: FinalizeReviewDisplay.details(of: update.change).map { Detail(label: $0.label, value: $0.value) })
  }
}
