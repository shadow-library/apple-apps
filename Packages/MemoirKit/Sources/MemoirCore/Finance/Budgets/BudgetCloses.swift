import Foundation
import ShadowCore
import ShadowStore

public enum BudgetCloseWrite: Sendable, Equatable {
  /// The close was issued with `deposit`: the record this write made, or the one another device's close made first, which stays.
  case closed(MemoirCommand, deposit: SavingsDeposit)
  /// Replay already holds a close for the period; nothing was written.
  case alreadyClosed
  /// Replay is halted at a command this build cannot read; nothing was written.
  case replayHalted
  /// The period no longer closes as the write reads the vault (a limit removed, the budget deleted, an expense waiting for a rate again).
  case notClosable
}

/// The only writer of period closes: `budget.closePeriod` and the period's `SavingsDepositRecord`, in the caller's main-store write.
///
/// The write judges the period again as it reads the vault at the instant and on the day it was first judged, so what it issues matches what the vault
/// holds when it commits. Two devices closing the same period both write: replay keeps the earlier close in replay order and the deposit record keeps the
/// earlier write, which may be the other device's (Facts Z1-7). Reads take the deposit record as the money truth; it names the close it was written with.
public enum BudgetCloses {
  public static func close(_ period: ClosablePeriod, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws(CommandIssueError) -> BudgetCloseWrite {
    let book: BudgetBook
    do throws(MemoirReadError) {
      book = try BudgetBook.load(from: ReadTransaction(database: transaction.database, registry: MemoirSchema.mainRegistry))
    } catch {
      throw CommandIssueError(reading: error)
    }
    guard book.replayHalt == nil else { return .replayHalted }
    guard !book.closedPeriods.contains(period.key) else { return .alreadyClosed }
    guard let fresh = BudgetCloseReads.closable(book, today: period.closedOn, nowMillis: period.judgedAtMillis).first(where: { $0.key == period.key }) else {
      return .notClosable
    }
    let body: BudgetPeriodClose
    do throws(CommandRefusal) {
      body = try BudgetPeriodClose(budgetId: fresh.budget.id, periodStart: fresh.period.start, outcome: fresh.outcome, deposited: fresh.deposited)
    } catch {
      throw .refused(error)
    }
    let command = try issuer.issue(.budgetClosePeriod(body), in: &transaction)
    let deposit = fresh.snapshot(command: command.id)
    if case .recorded = fresh.deposit { return .closed(command, deposit: deposit) }
    do throws(MemoirRecordError) {
      try SavingsDepositRecord(budget: fresh.budget.id, periodStart: fresh.period.start, deposit: deposit).create(in: &transaction)
    } catch {
      throw .record(error)
    }
    return .closed(command, deposit: deposit)
  }
}

extension CommandIssueError {
  init(reading error: MemoirReadError) {
    switch error {
    case .store(let store): self = .record(.store(store))
    case .finance(let finance): self = .refused(.finance(finance))
    case .invalidPage: self = .refused(.finance(.store(error.code)))
    }
  }
}
