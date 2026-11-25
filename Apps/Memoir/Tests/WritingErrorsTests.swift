import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import Testing

@testable import Memoir

@MainActor
@Suite("WritingErrors", TestTimeLimit.quick)
struct WritingErrorsTests {
  private struct Unknown: Error {}

  @Test("should use the reference's copy for a refusal with a reference code, with the code underneath")
  func usesReferenceCopy() {
    let presented = WritingErrors.presented(MemoirWriteError.command(.refused(.anchorNeedsStartTime)))

    #expect(presented == PresentedError(headline: "Anchor quests need a start time.", detail: "memoir_command.anchor_needs_start_time"))
    #expect(WritingErrors.presented(CommandIssueError.refused(.unknownTitle("crowned")))?.headline == "That title hasn’t been earned yet.")
    #expect(WritingErrors.presented(MemoirWriteError.command(.finance(.expenseFieldFixed("currency"))))?.headline.hasPrefix("A saved expense’s currency") == true)
    #expect(WritingErrors.presented(MetricsError.builtinFixed(.steps))?.headline == "Built-in metrics can’t be changed.")
    #expect(WritingErrors.presented(QuickLogError.issue(.refused(.categoryNotArchivable(CategoryKey("uncat")!))))?.headline.hasPrefix("Uncategorised and Subscriptions") == true)
  }

  @Test("should say what a refused refund needs, with the finance code underneath")
  func presentsRefundRefusals() {
    let refused = { (error: FinanceError) in WritingErrors.presented(MemoirWriteError.command(.refused(.finance(error)))) }

    #expect(refused(.nothingToRefund(UUID())) == PresentedError(headline: "There’s nothing left to refund on this expense.", detail: "memoir_finance.nothing_to_refund"))
    #expect(
      refused(.refundExceedsAmount(refund: 5, amount: 3))
        == PresentedError(headline: "That refund is more than what’s left on the expense.", detail: "memoir_finance.refund_exceeds_amount"))
    #expect(refused(.refundNotPositive(0)) == PresentedError(headline: "A refund has to be more than zero.", detail: "memoir_finance.refund_not_positive"))
  }

  @Test("should fall back to the generic headline with its code for a replay refusal the reference has no words for")
  func presentsAReplayRefusalWithoutWords() {
    let presented = WritingErrors.presented(ReplayRefusal.notAccountDay(TestClock.day(0)))

    #expect(presented == PresentedError(headline: PresentedError.genericHeadline, detail: "memoir_replay.cmd_002"))
  }

  @Test("should say the details were not valid for a refusal the reference answers with a validation error")
  func saysDetailsWereInvalid() {
    let presented = WritingErrors.presented(MemoirWriteError.command(.refused(.invalidField(field: "name", problem: .required))))

    #expect(presented == PresentedError(headline: "Some of the details weren’t valid.", detail: "memoir_command.invalid_field"))
  }

  @Test("should say a record is gone when the write named one that is absent")
  func saysARecordIsGone() {
    let ref = QuestRecord(id: UUID(), name: "Walk").ref

    #expect(WritingErrors.presented(MemoirWriteError.record(.absent(ref)))?.headline == "That’s no longer available.")
  }

  @Test("should present a failed store as the shell's store failure, however deep it is wrapped")
  func presentsStoreFailures() {
    let expected = PresentedError(headline: PresentedError.storeHeadline, detail: "store.database")

    #expect(WritingErrors.presented(MemoirWriteError.store(.database("disk full"))) == expected)
    #expect(WritingErrors.presented(MemoirWriteError.record(.store(.database("disk full")))) == expected)
    #expect(WritingErrors.presented(MemoirWriteError.command(.record(.store(.database("disk full"))))) == expected)
    #expect(WritingErrors.presented(QuickLogError.store(.database("disk full"))) == expected)
  }

  @Test("should show nothing for a cancelled write, however it is wrapped")
  func showsNothingWhenCancelled() {
    #expect(WritingErrors.presented(MemoirWriteError.cancelled) == nil)
    #expect(WritingErrors.presented(CancellationError()) == nil)
    #expect(WritingErrors.presented(StoreError.aborted(CancellationError())) == nil)
    #expect(WritingErrors.presented(QuickLogError.store(.aborted(CancellationError()))) == nil)
    #expect(WritingErrors.presented(MetricsError.store(.aborted(CancellationError()))) == nil)
  }

  @Test("should give a record of another class its code under the generic headline")
  func presentsARecordNotGeneral() {
    #expect(
      WritingErrors.presented(MemoirWriteError.recordNotGeneral(.weight)) == PresentedError(headline: PresentedError.genericHeadline, detail: "memoir_write.record_not_general"))
  }

  @Test("should give a budget refusal the owner's words, with its code underneath")
  func presentsBudgetRefusals() {
    let overlap = WritingErrors.presented(MemoirWriteError.command(.finance(.tripsOverlap(UUID()))))

    #expect(overlap == PresentedError(headline: "Trips can’t share a day. Change the dates so they don’t overlap.", detail: "memoir_finance.trips_overlap"))
    #expect(WritingErrors.presented(FinanceError.tripLimitLocked)?.headline == "A trip’s limit can’t be raised once the trip has started.")
    #expect(WritingErrors.presented(FinanceError.homeBudgetFixed)?.headline == "Home is always kept as a monthly budget in your home currency.")
    #expect(WritingErrors.presented(FinanceError.budgetAbsent(UUID()))?.headline == "That’s no longer available.")
    #expect(WritingErrors.presented(FinanceError.negativeLimit(-1))?.headline == "Some of the details weren’t valid.")
    #expect(WritingErrors.presented(FinanceError.limitChangedThisMonth)?.headline == "This month’s limit has already changed. Raise it again next month.")
    let earliest = MoneyDates.text(TestClock.day(0), locale: .autoupdatingCurrent)
    #expect(WritingErrors.presented(FinanceError.tripStartTooEarly(earliest: TestClock.day(0)))?.headline == "A trip can start on \(earliest) at the earliest.")
  }

  @Test("should ask for an update when a goal cannot be marked bought while replay is halted")
  func presentsReplayHalted() {
    #expect(
      WritingErrors.presented(MemoirWriteError.command(.refused(.finance(.replayHalted))))
        == PresentedError(headline: "Update Memoir on this device to finish this.", detail: "memoir_finance.replay_halted"))
  }

  @Test("should give a savings or goal refusal the owner's words, with its code underneath")
  func presentsSavingsRefusals() {
    let refused = { (error: FinanceError) in WritingErrors.presented(MemoirWriteError.command(.refused(.finance(error)))) }

    #expect(
      refused(.notOneOff(thresholdMinor: 5_000))
        == PresentedError(
          headline: "Savings are for one-off purchases, and this expense is below this budget’s one-off amount.", detail: "memoir_finance.not_one_off"))
    #expect(refused(.savingsInsufficient(availableMinor: 0))?.headline == "Your savings can’t cover that much right now.")
    let buyFrom = MoneyDates.text(TestClock.day(3), locale: .autoupdatingCurrent)
    #expect(
      refused(.coolingOffNotMet(buyFrom: TestClock.day(3)))?.headline
        == String(localized: "This goal can be bought from \(buyFrom), a few days after it was made.", table: "Writing"))
    #expect(refused(.goalLimitReached(maximum: 3))?.headline == "You can have up to 3 goals at once. Finish or set one aside first.")
    #expect(refused(.goalAbsent(UUID()))?.headline == "That’s no longer available.")
    #expect(refused(.goalExists(UUID()))?.headline == "Some of the details weren’t valid.")
  }

  @Test("should fall back to the generic headline for an error it does not know")
  func fallsBack() {
    #expect(WritingErrors.presented(Unknown()) == PresentedError(headline: PresentedError.genericHeadline, detail: nil))
  }

  @Test("should map a write's aborted errors to their typed cases")
  func mapsAbortedErrors() {
    guard case .command(.refused(.textUnexpected)) = MemoirWriteError(.aborted(CommandRefusal.textUnexpected)) else {
      Issue.record("a refusal thrown in a write is a command error")
      return
    }
    guard case .command(.finance(.overflow)) = MemoirWriteError(.aborted(FinanceError.overflow)) else {
      Issue.record("a finance error thrown in a write is a command error")
      return
    }
    guard case .clock(.dateOutOfRange) = MemoirWriteError(.aborted(CalendarError.dateOutOfRange)) else {
      Issue.record("a calendar error thrown in a write is a clock error")
      return
    }
    guard case .command(.command(.emptyNote)) = MemoirWriteError(.aborted(MemoirCommandError.emptyNote)) else {
      Issue.record("a command error thrown in a write is a command error")
      return
    }
    guard case .cancelled = MemoirWriteError(.aborted(CancellationError())) else {
      Issue.record("a cancelled write is cancelled")
      return
    }
    guard case .store(.database) = MemoirWriteError(.database("locked")) else {
      Issue.record("a store failure stays one")
      return
    }
  }
}
