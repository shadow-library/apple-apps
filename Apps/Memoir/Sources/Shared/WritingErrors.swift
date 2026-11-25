import Foundation
import MemoirCore
import ShadowAppShell
import ShadowCore
import ShadowStore

/// A failed write in the owner's words: the reference's copy for its error code where the reference refuses the same thing (`command-errors.ts`), the
/// shell's store headline when the store failed, and the code underneath. A cancelled write is nothing to show.
enum WritingErrors {
  static func presented(_ error: any Error) -> PresentedError? {
    presented(error, savings: nil)
  }

  /// With the currencies only the expense form knows, a refusal of a draw on savings names the one-off threshold and what is available.
  static func presented(_ error: any Error, savings: SavingsAmounts?) -> PresentedError? {
    if let savings, let headline = savingsHeadline(for: error, amounts: savings, locale: .autoupdatingCurrent) {
      return PresentedError(headline: headline, detail: (error as? any ShadowError)?.code)
    }
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
      case .tripStartTooEarly(let earliest):
        String(localized: "A trip can start on \(MoneyDates.text(earliest, locale: .autoupdatingCurrent)) at the earliest.", table: "Writing")
      case .limitChangedThisMonth: String(localized: "This month’s limit has already changed. Raise it again next month.", table: "Writing")
      case .refundExceedsAmount: String(localized: "That refund is more than what’s left on the expense.", table: "Writing")
      case .refundNotPositive: String(localized: "A refund has to be more than zero.", table: "Writing")
      case .nothingToRefund: String(localized: "There’s nothing left to refund on this expense.", table: "Writing")
      case .currencyTaken: String(localized: "There’s already a monthly budget in that currency.", table: "Writing")
      case .settingsAbsent: String(localized: "Choose your home currency first.", table: "Writing")
      case .goalNameRequired: String(localized: "Give the goal a name.", table: "Writing")
      case .goalSymbolRequired: String(localized: "Pick a symbol for the goal.", table: "Writing")
      case .goalTargetNotPositive: String(localized: "A goal’s target has to be more than zero.", table: "Writing")
      case .goalTargetDatePassed: String(localized: "A goal’s target date can’t be in the past.", table: "Writing")
      case .goalLimitReached: String(localized: "You can have up to 3 goals at once. Finish or set one aside first.", table: "Writing")
      case .goalNotActive: String(localized: "That goal is no longer active.", table: "Writing")
      case .goalNotPurchased: String(localized: "Pick this goal on the expense that bought it first.", table: "Writing")
      case .coolingOffNotMet(let buyFrom):
        String(
          localized: "This goal can be bought from \(MoneyDates.text(buyFrom, locale: .autoupdatingCurrent)), a few days after it was made.", table: "Writing")
      case .savingsNotPositive: String(localized: "The part from savings has to be more than zero.", table: "Writing")
      case .savingsExceedsAmount: String(localized: "The part from savings can’t be more than the expense.", table: "Writing")
      case .notOneOff: String(localized: "Savings are for one-off purchases, and this expense is below this budget’s one-off amount.", table: "Writing")
      case .savingsInsufficient: String(localized: "Your savings can’t cover that much right now.", table: "Writing")
      case .savingsAwaitingRate: String(localized: "This needs an exchange rate before it can be paid from savings.", table: "Writing")
      case .replayHalted: String(localized: "Update Memoir on this device to finish this.", table: "Writing")
      case .goalAbsent: String(localized: "That’s no longer available.", table: "Writing")
      case .unreadable, .store, .recordWrite: PresentedError.storeHeadline
      case .unknownCurrency, .currencyMismatch, .overflow, .rateNotPositive, .rateOutOfRange, .negativeBudget, .unknownFrequency, .customIntervalNotPositive,
        .billingDayOutOfRange, .dateOutOfRange, .expenseExists, .budgetExists, .negativeLimit, .goalExists:
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

  static func savingsHeadline(for error: any Error, amounts: SavingsAmounts, locale: Locale) -> String? {
    switch financeRefusal(error) {
    case .notOneOff(let threshold?)?:
      let amount = MoneyText.formatted(threshold, amounts.budget, locale: locale)
      return String(localized: "Savings are for one-off purchases: in this budget, \(amount) or more.", table: "Writing")
    case .savingsInsufficient(let available)?:
      return String(localized: "Your savings can cover up to \(MoneyText.formatted(available, amounts.home, locale: locale)) right now.", table: "Writing")
    default:
      return nil
    }
  }

  private static func financeRefusal(_ error: any Error) -> FinanceError? {
    switch error {
    case let error as FinanceError: error
    case MemoirWriteError.command(.finance(let error)), MemoirWriteError.command(.refused(.finance(let error))): error
    case CommandIssueError.finance(let error), CommandIssueError.refused(.finance(let error)): error
    default: nil
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

/// The currencies a refused draw on savings counts in: the one-off threshold in the expense's budget's, what is available in the home currency.
nonisolated struct SavingsAmounts: Equatable, Sendable {
  let budget: CurrencyCode
  let home: CurrencyCode
}

extension MemoirWriteError {
  fileprivate var isCancelled: Bool {
    guard case .cancelled = self else { return false }
    return true
  }
}
