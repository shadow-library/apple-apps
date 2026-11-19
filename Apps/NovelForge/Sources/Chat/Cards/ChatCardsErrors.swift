import Foundation
import NovelForgeCore

/// A refusal as a card shows it, with the one recovery the card can run for it.
struct ChatCardNotice: Equatable {
  enum Recovery: Equatable {
    /// RFN_006 on a twin: the other reply's change that created the same item was undone, which removed it; redoing that change brings it back.
    case redoTwin(proposal: UUID, index: Int)
  }

  let error: PresentedError
  var recovery: Recovery?
}

enum ChatCardsErrors {
  enum Write {
    case apply
    case discard
    case undo
    case redo
    case revert
    case impact
  }

  static func presented(_ refusal: ChatCardRefusal, during write: Write) -> PresentedError {
    if refusal.isStore { return PresentedError(headline: storeHeadline, detail: refusal.code) }
    return PresentedError(headline: headline(refusal.code, during: write) ?? genericHeadline, detail: refusal.code)
  }

  /// A change already removed by its twin: two replies answered one message on two devices and both created the same item (F26 finding A).
  static func twinRemoved(_ refusal: ChatCardRefusal) -> PresentedError {
    PresentedError(
      headline: String(
        localized: "This was already undone by another reply that added the same thing, so there is nothing left to undo. Redo that reply's change to bring it back.",
        table: "ChatCards"),
      detail: refusal.code)
  }

  /// Why a selected step of an applied card did not run, as its row shows it.
  static func failure(_ code: String) -> String {
    headline(code, during: .apply) ?? genericHeadline
  }

  static var conflicted: String {
    String(localized: "Your story moved on since this was suggested. Ask again for a fresh change.", table: "ChatCards")
  }

  private static var genericHeadline: String { String(localized: "Something went wrong.", table: "ChatCards") }

  private static var storeHeadline: String { String(localized: "Your data could not be read or saved.", table: "ChatCards") }

  // proposal-apply.service.ts, proposal-revert.service.ts and app-error-code.ts:150-218 name these codes; each gets the words the author acts on
  private static func headline(_ code: String, during write: Write) -> String? {
    switch code {
    case "RFN_001": String(localized: "These changes could not be found. They may have been removed on another device.", table: "ChatCards")
    case "RFN_002": String(localized: "These changes were already answered, perhaps on another device.", table: "ChatCards")
    case "refinement.unreadable_record": String(localized: "These changes are stored in a form this version cannot read.", table: "ChatCards")
    case "RFN_003" where write == .redo:
      String(localized: "What this change touches has changed since it was undone, so it can't be redone.", table: "ChatCards")
    case "RFN_003": conflicted
    case "RFN_009", "DRF_009", "CNT_002", "DRF_014", "VOL_004": String(localized: "Select this step on its own and apply it deliberately.", table: "ChatCards")
    case "refinement.not_yet_available": String(localized: "This step isn't available yet.", table: "ChatCards")
    case "refinement.automatic_action", "refinement.automatic_always_card", "refinement.sources_mismatch", "RFN_004":
      String(localized: "One of these changes is no longer valid. Leave it out and apply the rest.", table: "ChatCards")
    case "RFN_005": String(localized: "That chapter's plan is already final, so it can't change.", table: "ChatCards")
    case "PLN_008": String(localized: "This plan is out of date: the story has moved on to a later chapter. Plan again.", table: "ChatCards")
    case "RFN_010", "DRF_002": String(localized: "That chapter is final, so its prose can't change.", table: "ChatCards")
    case "RFN_012": String(localized: "That chapter is isolated, so the chat can't rewrite it. Edit it in the chapter instead.", table: "ChatCards")
    case "RFN_020": String(localized: "Two of the selected rewrites change the same words. Select only one of them.", table: "ChatCards")
    case "RFN_021": String(localized: "A rewrite no longer matches its chapter. Leave it out to apply the others, or ask again.", table: "ChatCards")
    case "refinement.unsettled_working_copy", "refinement.approval_over_moved_draft":
      String(localized: "That chapter has unsaved edits on this device. Save or close the chapter, then try again.", table: "ChatCards")
    case "refinement.unreadable_references", "refinement.last_advanced_untracked", "refinement.unstorable_value", "refinement.malformed_inverse":
      String(localized: "Something this change needs is stored in a form this version cannot read.", table: "ChatCards")
    case "refinement.partial_write", "refinement.rewrite_beside_whole_draft":
      String(localized: "These changes could not be applied together, so nothing was changed.", table: "ChatCards")
    case "AI_024": String(localized: "Unrestricted writing isn't available in this version.", table: "ChatCards")
    case "DRF_001": String(localized: "That chapter has no draft to act on.", table: "ChatCards")
    case "DRF_004": String(localized: "Approve the chapter's draft before finalizing it.", table: "ChatCards")
    case "DRF_007", "DRF_017": String(localized: "That draft is out of date with its plan. Revise it before approving it.", table: "ChatCards")
    case "DRF_013": String(localized: "The chapter changed after this was suggested, so it wasn't approved. Ask again to approve the version you see.", table: "ChatCards")
    case "DRF_018", "FIN_001": String(localized: "Finalize the chapters before this one first.", table: "ChatCards")
    case "VOL_001", "VOL_003": String(localized: "That volume isn't the active one, so its goal can't be marked met.", table: "ChatCards")
    case "refinement.action_skipped": String(localized: "Skipped because an earlier step failed.", table: "ChatCards")
    case "RFN_007": String(localized: "Nothing here can be undone any more.", table: "ChatCards")
    case "RFN_011": String(localized: "That change isn't part of these changes.", table: "ChatCards")
    case "RFN_014": String(localized: "This change can only be undone together with the rest of its changes.", table: "ChatCards")
    case "refinement.change_unreadable": String(localized: "This change is stored in a form this version cannot read, so it can't be undone or redone here.", table: "ChatCards")
    case "RFN_015": String(localized: "Other changes rely on this one. Undo them first.", table: "ChatCards")
    case "RFN_016": String(localized: "This change relies on changes that are undone. Redo them first.", table: "ChatCards")
    case "RFN_017": String(localized: "These changes were undone together, so one can't be redone on its own.", table: "ChatCards")
    case "RFN_006": String(localized: "What this change touched has changed since, so it can't be undone.", table: "ChatCards")
    case "RFN_018": String(localized: "This change couldn't be put back exactly as it was, so nothing was undone.", table: "ChatCards")
    case "refinement.redo_did_not_restore":
      String(localized: "This change can't be brought back exactly as it was. Ask the chat to suggest it again and apply it from the new card.", table: "ChatCards")
    case "refinement.changes_not_synced":
      String(localized: "Some of these changes are still arriving from another device. Try again once they've synced.", table: "ChatCards")
    case "refinement.declined_changed":
      String(localized: "Changes left out of this card have changed since, perhaps on another device.", table: "ChatCards")
    case "refinement.impact_unavailable": String(localized: "What relies on this change can't be read on this device right now.", table: "ChatCards")
    case "LDG_006", "LDG_007", "LDG_008": String(localized: "The idea could not be set aside in your Notebook.", table: "ChatCards")
    default: nil
    }
  }
}
