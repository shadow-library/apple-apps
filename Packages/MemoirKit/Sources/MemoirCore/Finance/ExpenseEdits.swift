import Foundation
import ShadowCore
import ShadowStore

/// The owner's expense writes, each in the caller's main-store write with its command, as the reference's `finance-commands.service.ts` handles
/// `expense.create`, `expense.update` and `expense.delete`. An edit also appends the `ExpenseChangeRecord` of what moved, so the history shows the change
/// on every device; a creation or a deletion purges the expense's change records, which hold its old notes and merchants
/// (`ExpenseAuditRepository.removeForExpense`).
public enum ExpenseEdits {
  /// Creates the expense with its rate captured. An id already held as a deleted expense is created again: its fields take the new values, but the
  /// currency must be the one it was first written with (`FIN_006`), and it keeps its first rate and logging time, which never change. It comes back
  /// without the receipt it had: the deletion purged that receipt's record.
  @discardableResult
  public static func create(_ expense: ExpenseRecord, source: ExpenseSource = .manual, issuer: CommandIssuer, in transaction: inout WriteTransaction)
    throws(CommandIssueError) -> (command: MemoirCommand, expense: ExpenseRecord)
  {
    let ref = ExpenseRecord.ref(expense.id)
    let written: ExpenseRecord
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
      if recreated.receipt == entry.record.receipt { recreated.receipt = nil }
      let restored = recreated
      try record { () throws(MemoirRecordError) in
        try ExpenseRecord.restore(ref, in: &transaction)
        try ExpenseRecord.edit(ref, in: &transaction) { $0 = restored }
      }
      written = restored
    }
    try record { () throws(MemoirRecordError) in _ = try ExpenseChangeRecord.purge(expense: expense.id, in: &transaction) }
    return (try issuer.issue(.expenseCreate(ExpenseCreation(id: expense.id, source: source)), in: &transaction), written)
  }

  /// `nil`, writing nothing, when the edit moves no field the owner sees. Moving the currency, rate, receipt or logging time is refused
  /// (`expenseFieldFixed`, the reference's `FIN_006` for the currency) before anything is written.
  @discardableResult
  public static func update(
    _ id: UUID, issuer: CommandIssuer, in transaction: inout WriteTransaction, _ change: (inout ExpenseRecord) throws(MemoirRecordError) -> Void
  ) throws(CommandIssueError) -> MemoirCommand? {
    let current = try present(id, in: transaction)
    var edited = current
    try record { () throws(MemoirRecordError) in try change(&edited) }
    if let field = fixedField(moved: current, to: edited) { throw .refused(.finance(.expenseFieldFixed(field.rawValue))) }
    let changes = ExpenseFieldChange.changes(from: current, to: edited)
    guard !changes.isEmpty else { return nil }
    let command = try issuer.issue(.expenseUpdate(RecordReference(id: id)), in: &transaction)
    let updated = edited
    try record { () throws(MemoirRecordError) in
      try ExpenseRecord.edit(id: id, in: &transaction) { $0 = updated }
      try ExpenseChangeRecord(command: command.id, expense: id, changes: changes).append(in: &transaction)
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
