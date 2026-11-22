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
