import Foundation
import ShadowCore
import ShadowStore

/// How much of an expense a refund returns, in minor units of the expense's currency.
public enum RefundAmount: Sendable, Hashable {
  case full
  case partial(Int64)
}

/// The owner's expense writes, each in the caller's main-store write with its command, as the reference's `finance-commands.service.ts` handles
/// `expense.create`, `expense.update` and `expense.delete`. An edit also appends the `ExpenseChangeRecord` of what moved, so the history shows the change
/// on every device; a creation or a deletion purges the expense's change records, which hold its old notes and merchants
/// (`ExpenseAuditRepository.removeForExpense`).
public enum ExpenseEdits {
  /// Creates the expense with its rate captured, refusing a part paid from savings or a goal `SavingsWithdrawals` does not admit. An id already held as a
  /// deleted expense is created again: its fields take the new values, but the currency must be the one it was first written with (`FIN_006`), and it
  /// keeps its first rate, logging time and cycle seed, which never change. It comes back without the receipt it had: the deletion purged that receipt's
  /// record.
  @discardableResult
  public static func create(_ expense: ExpenseRecord, source: ExpenseSource = .manual, issuer: CommandIssuer, in transaction: inout WriteTransaction)
    throws(CommandIssueError) -> (command: MemoirCommand, expense: ExpenseRecord)
  {
    let ref = ExpenseRecord.ref(expense.id)
    let written: ExpenseRecord
    try SavingsWithdrawals.check(expense, replacing: nil, issuer: issuer, in: transaction)
    switch try reading(ref, in: transaction) {
    case .absent:
      do throws(FinanceError) {
        written = try expense.createCapturingRate(in: &transaction)
      } catch {
        throw .finance(error)
      }
    case .unreadable(let reason):
      throw .record(.unreadable(ref, reason))
    case .readable(let entry):
      guard entry.isRemoved else { throw .refused(.finance(.expenseExists(expense.id))) }
      guard entry.record.currency == expense.currency else { throw .refused(.finance(.expenseFieldFixed(ExpenseField.currency.rawValue))) }
      var recreated = expense
      recreated.rate = entry.record.rate
      recreated.loggedAtMillis = entry.record.loggedAtMillis
      recreated.cycle = entry.record.cycle
      if recreated.receipt == entry.record.receipt { recreated.receipt = nil }
      let restored = recreated
      try record { () throws(MemoirRecordError) in
        try ExpenseRecord.restore(ref, in: &transaction)
        try ExpenseRecord.edit(ref, in: &transaction) { $0 = restored }
      }
      written = restored
    }
    try record { () throws(MemoirRecordError) in _ = try ExpenseChangeRecord.purge(expense: expense.id, in: &transaction) }
    let occurredOn = Ruleset.current.money == nil ? nil : expense.occurredOn
    return (try issuer.issue(.expenseCreate(ExpenseCreation(id: expense.id, source: source, occurredOn: occurredOn)), in: &transaction), written)
  }

  /// `nil`, writing nothing, when the edit moves no field the owner sees. A new or larger part paid from savings, or a goal named afresh, is checked as
  /// `SavingsWithdrawals` says; one that stays or falls is not. Moving the currency, rate, receipt, logging time or cycle seed is refused
  /// (`expenseFieldFixed`, the reference's `FIN_006` for the currency) before anything is written. Only the fields it moves are written, so a cycle's
  /// expense keeps following its seed in every other field.
  @discardableResult
  public static func update(
    _ id: UUID, issuer: CommandIssuer, in transaction: inout WriteTransaction, _ change: (inout ExpenseRecord) throws(MemoirRecordError) -> Void
  ) throws(CommandIssueError) -> MemoirCommand? {
    try apply(id, reason: nil, issuer: issuer, in: &transaction, change)
  }

  /// Moves the amount to what is left after the refund and returns the part paid from savings that no longer fits to savings, in the same `expense.update`;
  /// the change record carries `reason: .refund`. A full refund leaves the expense at zero, kept and shown as refunded; a partial one that equals the amount is
  /// a full one. The expense's date and budget stay, so the refund reduces the month the expense was counted in.
  @discardableResult
  public static func refund(_ id: UUID, amount: RefundAmount, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws(CommandIssueError) -> MemoirCommand {
    let current = try present(id, in: transaction)
    guard current.amountMinor > 0 else { throw .refused(.finance(.nothingToRefund(id))) }
    let remaining: Int64
    switch amount {
    case .full:
      remaining = 0
    case .partial(let refunded):
      guard refunded > 0 else { throw .refused(.finance(.refundNotPositive(refunded))) }
      guard refunded <= current.amountMinor else { throw .refused(.finance(.refundExceedsAmount(refund: refunded, amount: current.amountMinor))) }
      remaining = current.amountMinor - refunded
    }
    let command = try apply(id, reason: .refund, issuer: issuer, in: &transaction) { expense throws(MemoirRecordError) in
      expense.amountMinor = remaining
      guard let fromSavings = expense.fromSavingsMinor else { return }
      let clamped = min(fromSavings, remaining)
      expense.fromSavingsMinor = clamped > 0 ? clamped : nil
    }
    guard let command else { preconditionFailure("a refund of a positive amount moves the amount") }
    return command
  }

  private static func apply(
    _ id: UUID, reason: ExpenseChangeReason?, issuer: CommandIssuer, in transaction: inout WriteTransaction, _ change: (inout ExpenseRecord) throws(MemoirRecordError) -> Void
  ) throws(CommandIssueError) -> MemoirCommand? {
    let current = try present(id, in: transaction)
    var edited = current
    try record { () throws(MemoirRecordError) in try change(&edited) }
    if let field = fixedField(moved: current, to: edited) { throw .refused(.finance(.expenseFieldFixed(field.rawValue))) }
    let changes = ExpenseFieldChange.changes(from: current, to: edited)
    guard !changes.isEmpty else { return nil }
    try SavingsWithdrawals.check(edited, replacing: current, issuer: issuer, in: transaction)
    let command = try issuer.issue(.expenseUpdate(RecordReference(id: id)), in: &transaction)
    let updated = edited
    try record { () throws(MemoirRecordError) in
      try ExpenseRecord.edit(id: id, in: &transaction) { $0 = updated }
      try ExpenseChangeRecord(command: command.id, expense: id, changes: changes, reason: reason.map { .known($0) }).append(in: &transaction)
    }
    return command
  }

  /// Clears the note and merchant, marks the expense removed, issues `expense.delete` and purges its change records, so no replica keeps the owner's words
  /// of an expense the reference would have deleted outright (`expense.repository.ts:53-59`). The entity itself is never purged: a purge wins every merge
  /// and would block creating the id again, and with it a confirmed cycle's expense under its derived id. Its receipt record is purged, as the reference
  /// cascades the receipt (`finance-commands.service.ts:244-250`), so nothing names the image's blob any more and the sync kernel releases it.
  @discardableResult
  public static func delete(_ id: UUID, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws(CommandIssueError) -> MemoirCommand {
    let receipt = try present(id, in: transaction).receipt
    try record { () throws(MemoirRecordError) in
      try ExpenseRecord.edit(id: id, in: &transaction) { expense in
        expense.note = nil
        expense.merchant = nil
      }
      try ExpenseRecord.remove(ExpenseRecord.ref(id), in: &transaction)
      try ExpenseChangeRecord.purge(expense: id, in: &transaction)
      if let receipt { try ReceiptRecord.purge(receipt, in: &transaction) }
    }
    return try issuer.issue(.expenseDelete(RecordReference(id: id)), in: &transaction)
  }

  private static func fixedField(moved before: ExpenseRecord, to after: ExpenseRecord) -> ExpenseField? {
    if before.currency != after.currency { return .currency }
    if before.rate != after.rate { return .rate }
    if before.receipt != after.receipt { return .receipt }
    if before.loggedAtMillis != after.loggedAtMillis { return .loggedAtMillis }
    if before.cycle != after.cycle { return .cycle }
    return nil
  }

  private static func present(_ id: UUID, in transaction: borrowing WriteTransaction) throws(CommandIssueError) -> ExpenseRecord {
    let ref = ExpenseRecord.ref(id)
    switch try reading(ref, in: transaction) {
    case .readable(let entry) where !entry.isRemoved: return entry.record
    case .readable, .absent: throw .record(.absent(ref))
    case .unreadable(let reason): throw .record(.unreadable(ref, reason))
    }
  }

  private static func reading(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(CommandIssueError) -> MemoirReading<MemoirEntry<ExpenseRecord>> {
    do throws(StoreError) {
      return try ExpenseRecord.read(ref, in: transaction)
    } catch {
      throw .record(.store(error))
    }
  }

  private static func record(_ body: () throws(MemoirRecordError) -> Void) throws(CommandIssueError) {
    do throws(MemoirRecordError) {
      try body()
    } catch {
      throw .record(error)
    }
  }
}
