import Foundation
import ShadowCore
import ShadowStore

/// What replay did with one command. A refusal leaves the state as it was, as the reference's rolled-back transaction does.
public enum ReplayOutcome: Sendable, Hashable {
  case applied
  /// A racing action got there first; the reference answers `superseded` and changes nothing.
  case superseded
  case rejected(ReplayRejection)
  case refused(ReplayRefusal)
}

/// The reference's `status: 'rejected'` answers: nothing changes and the device is asked to decide.
public enum ReplayRejection: String, Sendable, Hashable {
  case rescheduleCap = "reschedule-cap"
  case weightNeedsConfirmation = "needs-confirmation"
}

/// A command the state no longer admits, named by the reference's `AppErrorCode`.
public enum ReplayRefusal: ShadowError, Hashable {
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
  case expenseNotFound
  case subscriptionNotFound
  case mealPresetNotFound

  public var referenceCode: String {
    switch self {
    case .alreadyRescheduled: "QST_001"
    case .questNotFound: "QST_002"
    case .anchorNeedsStartTime: "QST_003"
    case .noOccurrence: "QST_004"
    case .postponeUnavailable: "QST_005"
    case .editWindowClosed: "QST_006"
    case .logNotFound: "QST_007"
    case .rescheduleUnavailable: "QST_008"
    case .notStarted: "QST_009"
    case .notAccountDay: "CMD_002"
    case .noPendingRecovery: "RCV_001"
    case .lockedQuestNotFound: "LCK_001"
    case .dayClosed: "LCK_002"
    case .notEnoughCoins: "HRO_001"
    case .cosmeticNotOwned: "CSM_003"
    case .titleNotEarned: "TTL_001"
    case .metricNotFound: "MET_002"
    case .expenseNotFound: "FIN_003"
    case .subscriptionNotFound: "FIN_004"
    case .mealPresetNotFound: "QLG_001"
    }
  }

  public var code: String { "memoir_replay.\(referenceCode.lowercased())" }

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
    case .expenseNotFound: "The expense does not exist."
    case .subscriptionNotFound: "The subscription does not exist or was deleted."
    case .mealPresetNotFound: "The meal preset does not exist or was deleted."
    }
  }
}

/// Something the owner is told about once replay settles, such as a purchase a merge withdrew.
public enum ReplayNotice: Sendable, Hashable {
  case purchaseWithdrawn(command: UUID, cosmetic: CosmeticID, balance: Int, price: Int)
}

/// Replay stops at the first command this app cannot read; the state stays as it was before that command, and the app asks to be updated.
public enum ReplayHalt: Sendable, Hashable {
  case unreadableCommand(EntityRef)
  case unknownCommandType(command: UUID, type: String)
  case rulesetUnavailable(command: UUID, version: Int)
}
