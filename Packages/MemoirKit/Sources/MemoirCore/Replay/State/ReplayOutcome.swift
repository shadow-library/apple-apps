import Foundation
import ShadowCore
import ShadowStore

/// What replay did with one command. A refusal leaves the state as it was, as the reference's rolled-back transaction does.
public enum ReplayOutcome: Sendable, Hashable, Codable {
  case applied
  /// A racing action got there first; the reference answers `superseded` and changes nothing.
  case superseded
  case rejected(ReplayRejection)
  case refused(ReplayRefusal)
}

/// The reference's `status: 'rejected'` answers: nothing changes and the device is asked to decide.
public enum ReplayRejection: String, Sendable, Hashable, Codable {
  case rescheduleCap = "reschedule-cap"
  case weightNeedsConfirmation = "needs-confirmation"
}

/// A command the state no longer admits, named by the reference's `AppErrorCode` where the reference refuses it too.
public enum ReplayRefusal: ShadowError, Hashable, Codable {
  case alreadyRescheduled
  case questNotFound
  case anchorNeedsStartTime
  case noOccurrence(LocalDate)
  case postponeUnavailable
  case editWindowClosed
  case logNotFound
  case rescheduleUnavailable
  case notStarted(LocalDate)
  case notAccountDay(LocalDate)
  case noPendingRecovery
  case lockedQuestNotFound
  case dayClosed
  case notEnoughCoins(balance: Int, required: Int)
  case cosmeticNotOwned(CosmeticID)
  case titleNotEarned(TitleID)
  case metricNotFound
  case builtinMetric
  case expenseNotFound
  case subscriptionNotFound
  case mealPresetNotFound
  /// The body needs a newer ruleset than the one the command was stamped with (`MemoirCommandBody.minimumRulesetVersion`).
  case needsNewerRuleset(minimum: Int)

  private enum Identity {
    case reference(String)
    case native(String)
  }

  private var identity: Identity {
    switch self {
    case .alreadyRescheduled: .reference("QST_001")
    case .questNotFound: .reference("QST_002")
    case .anchorNeedsStartTime: .reference("QST_003")
    case .noOccurrence: .reference("QST_004")
    case .postponeUnavailable: .reference("QST_005")
    case .editWindowClosed: .reference("QST_006")
    case .logNotFound: .reference("QST_007")
    case .rescheduleUnavailable: .reference("QST_008")
    case .notStarted: .reference("QST_009")
    case .notAccountDay: .reference("CMD_002")
    case .noPendingRecovery: .reference("RCV_001")
    case .lockedQuestNotFound: .reference("LCK_001")
    case .dayClosed: .reference("LCK_002")
    case .notEnoughCoins: .reference("HRO_001")
    case .cosmeticNotOwned: .reference("CSM_003")
    case .titleNotEarned: .reference("TTL_001")
    case .metricNotFound: .reference("MET_002")
    case .builtinMetric: .reference("MET_003")
    case .expenseNotFound: .reference("FIN_003")
    case .subscriptionNotFound: .reference("FIN_004")
    case .mealPresetNotFound: .reference("QLG_001")
    case .needsNewerRuleset: .native("needs_newer_ruleset")
    }
  }

  public var referenceCode: String? {
    guard case .reference(let code) = identity else { return nil }
    return code
  }

  public var code: String {
    switch identity {
    case .reference(let code): "memoir_replay.\(code.lowercased())"
    case .native(let code): "memoir_replay.\(code)"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .alreadyRescheduled: "This occurrence has already been rescheduled."
    case .questNotFound: "The quest does not exist or was deleted."
    case .anchorNeedsStartTime: "An anchor quest needs a start time."
    case .noOccurrence(let date): "The quest has no occurrence on \(date)."
    case .postponeUnavailable: "This quest cannot be postponed."
    case .editWindowClosed: "The quest log is outside its 7-day edit window."
    case .logNotFound: "There is no log for this occurrence."
    case .rescheduleUnavailable: "This quest cannot be rescheduled."
    case .notStarted(let date): "The occurrence on \(date) had not started when the command was issued."
    case .notAccountDay(let date): "The command was issued on \(date), which is no longer the account's day."
    case .noPendingRecovery: "No Recovery quest was pending on that day."
    case .lockedQuestNotFound: "A quest named by the plan lock does not exist or was deleted."
    case .dayClosed: "The day was already closed, or not yet open, so its plan cannot be locked."
    case .notEnoughCoins(let balance, let required): "The purchase needs \(required) coins, but the balance was \(balance)."
    case .cosmeticNotOwned(let cosmetic): "The cosmetic \(cosmetic.rawValue) was not unlocked."
    case .titleNotEarned(let title): "The title \(title.rawValue) was not earned."
    case .metricNotFound: "The metric does not exist."
    case .builtinMetric: "A built-in metric keeps its definition and cannot be deleted."
    case .expenseNotFound: "The expense does not exist."
    case .subscriptionNotFound: "The subscription does not exist or was deleted."
    case .mealPresetNotFound: "The meal preset does not exist or was deleted."
    case .needsNewerRuleset(let minimum): "The command needs ruleset \(minimum) or later, but was stamped with an older one."
    }
  }
}

/// Something the owner is told about once replay settles, such as a purchase a merge withdrew.
public enum ReplayNotice: Sendable, Hashable, Codable {
  case purchaseWithdrawn(command: UUID, cosmetic: CosmeticID, balance: Int, price: Int)
}

/// Replay stops at the first command this app cannot read; the state stays as it was before that command, and the app asks to be updated.
public enum ReplayHalt: Sendable, Hashable, Codable {
  case unreadableCommand(EntityRef)
  case unknownCommandType(command: UUID, type: String)
  case rulesetUnavailable(command: UUID, version: Int)
}
