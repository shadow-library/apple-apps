import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore

/// A failed write in the owner's words: the reference's copy for its error code where the reference refuses the same thing (`command-errors.ts`), the
/// shell's store headline when the store failed, and the code underneath. A cancelled write is nothing to show.
enum WritingErrors {
  static func presented(_ error: any Error) -> PresentedError? {
    guard !isCancellation(error) else { return nil }
    if let headline = headline(for: error) { return PresentedError(headline: headline, detail: (error as? any ShadowError)?.code) }
    if let store = storeFailure(of: error) { return PresentedError(store) }
    return PresentedError(headline: PresentedError.genericHeadline, detail: (error as? any ShadowError)?.code)
  }

  static func headline(for error: any Error) -> String? {
    switch error {
    case let error as MemoirWriteError:
      switch error {
      case .command(let error): headline(for: error)
      case .record(let error): headline(for: error)
      case .clock(let error): headline(for: error)
      case .recordNotGeneral, .store, .cancelled: nil
      }
    case let error as CommandIssueError:
      switch error {
      case .refused(let refusal): headline(for: refusal)
      case .clock(let error): headline(for: error)
      case .command: invalidDetails
      case .record(let error): headline(for: error)
      case .finance(let error): headline(for: error)
      }
    case let refusal as CommandRefusal:
      switch refusal {
      case .finance(let error): headline(for: error)
      default: refusal.referenceCode.flatMap(copy(referenceCode:)) ?? invalidDetails
      }
    case let refusal as ReplayRefusal:
      refusal.referenceCode.flatMap(copy(referenceCode:))
    case let error as FinanceError:
      switch error {
      case .expenseFieldFixed: copy(referenceCode: "FIN_006")
      case .subscriptionAbsent: copy(referenceCode: "FIN_004")
      case .budgetAbsent: String(localized: "That’s no longer available.", table: "Writing")
      case .homeBudgetFixed: String(localized: "Home is always kept as a monthly budget in your home currency.", table: "Writing")
      case .budgetFieldFixed: String(localized: "A budget’s currency and kind can’t be changed. Make a new budget instead.", table: "Writing")
      case .budgetNameRequired: String(localized: "Give the budget a name.", table: "Writing")
      case .budgetLimitRequired: String(localized: "Set a limit for the budget.", table: "Writing")
      case .invalidTripDates: String(localized: "A trip ends on or after the day it starts.", table: "Writing")
      case .tripsOverlap: String(localized: "Trips can’t share a day. Change the dates so they don’t overlap.", table: "Writing")
      case .tripLimitLocked: String(localized: "A trip’s limit can’t be raised once the trip has started.", table: "Writing")
      case .tripStartFixed: String(localized: "A trip that has started keeps its first day.", table: "Writing")
      case .tripStartTooEarly: String(localized: "A trip can start at most 3 days ago.", table: "Writing")
      case .limitChangedThisMonth: String(localized: "This month’s limit has already changed. Raise it again next month.", table: "Writing")
      case .refundExceedsAmount: String(localized: "That refund is more than what’s left on the expense.", table: "Writing")
      case .refundNotPositive: String(localized: "A refund has to be more than zero.", table: "Writing")
      case .nothingToRefund: String(localized: "There’s nothing left to refund on this expense.", table: "Writing")
      case .currencyTaken: String(localized: "There’s already a monthly budget in that currency.", table: "Writing")
      case .unreadable, .store, .recordWrite: PresentedError.storeHeadline
      case .unknownCurrency, .currencyMismatch, .overflow, .rateNotPositive, .rateOutOfRange, .negativeBudget, .unknownFrequency, .customIntervalNotPositive,
        .billingDayOutOfRange, .dateOutOfRange, .expenseExists, .budgetExists, .negativeLimit:
        invalidDetails
      }
    case let error as MemoirRecordError:
      switch error {
      case .absent: String(localized: "That’s no longer available.", table: "Writing")
      case .conflictingItem: String(localized: "It was changed somewhere else first.", table: "Writing")
      case .firstWriterField, .identityChanged: invalidDetails
      case .unreadable: PresentedError.storeHeadline
      case .store: nil
      }
    case let error as MetricsError:
      switch error {
      case .metricAbsent, .builtinFixed: error.referenceCode.flatMap(copy(referenceCode:))
      case .refused(let refusal): headline(for: refusal)
      case .issue(let error): headline(for: error)
      case .record(let error): headline(for: error)
      case .calendar(let error): headline(for: error)
      case .store, .notReader: nil
      }
    case let error as QuickLogError:
      switch error {
      case .issue(let error): headline(for: error)
      case .record(let error): headline(for: error)
      case .store: nil
      }
    case is CalendarError:
      String(localized: "The date on this device is outside the years Memoir can record. Check the device’s date and time.", table: "Writing")
    default:
      nil
    }
  }

  private static var invalidDetails: String { String(localized: "Some of the details weren’t valid.", table: "Writing") }

  private static func copy(referenceCode: String) -> String? {
    switch referenceCode {
    case "QST_003": String(localized: "Anchor quests need a start time.", table: "Writing")
    case "LCK_001": String(localized: "That quest isn’t in your plan any more.", table: "Writing")
    case "HRO_001": String(localized: "You don’t have enough coins for that.", table: "Writing")
    case "CSM_002": String(localized: "That item isn’t available.", table: "Writing")
    case "CSM_003": String(localized: "Unlock it before equipping it.", table: "Writing")
    case "CSM_004": String(localized: "That item comes with an achievement, not with coins.", table: "Writing")
    case "TTL_001": String(localized: "That title hasn’t been earned yet.", table: "Writing")
    case "FIN_004": String(localized: "That subscription no longer exists.", table: "Writing")
    case "FIN_005": String(localized: "That category no longer exists.", table: "Writing")
    case "FIN_006": String(localized: "A saved expense’s currency can’t be changed. Delete it and add it again.", table: "Writing")
    case "FIN_007": String(localized: "Uncategorised and Subscriptions are always kept, so they can’t be archived.", table: "Writing")
    case "MET_002": String(localized: "That metric no longer exists.", table: "Writing")
    case "MET_003": String(localized: "Built-in metrics can’t be changed.", table: "Writing")
    default: nil
    }
  }

  private static func isCancellation(_ error: any Error) -> Bool {
    switch error {
    case is CancellationError, MemoirWriteError.cancelled: true
    case let error as StoreError: MemoirWriteError(error).isCancelled
    default: storeFailure(of: error).map { MemoirWriteError($0).isCancelled } ?? false
    }
  }

  private static func storeFailure(of error: any Error) -> StoreError? {
    switch error {
    case let error as StoreError: error
    case let error as any DomainFailure: error.storeFailure
    case let error as QuickLogError:
      switch error {
      case .store(let store), .record(.store(let store)), .issue(.record(.store(let store))): store
      case .issue, .record: nil
      }
    case let error as MetricsError:
      switch error {
      case .store(let store), .record(.store(let store)), .issue(.record(.store(let store))): store
      default: nil
      }
    default: nil
    }
  }
}

extension MemoirWriteError {
  fileprivate var isCancelled: Bool {
    guard case .cancelled = self else { return false }
    return true
  }
}
