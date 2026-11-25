import Foundation
import ShadowStore

/// The only writer of the owner's choices on a category's record that issue no command, in the caller's main-store write.
public enum CategoryEdits {
  /// Records whether the owner counts a category as essential, nil going back to `CategoryEssentials`' default. A category without its record yet is
  /// written with `label` and the choice alone, never `archived`, so an archive made on a device whose write has not arrived stays in force after the
  /// merge. Nil, writing nothing, when the choice is already recorded.
  @discardableResult
  public static func setEssential(_ key: CategoryKey, _ essential: Bool?, label: String, in transaction: inout WriteTransaction) throws(FinanceError)
    -> ExpenseCategoryRecord?
  {
    let reading: MemoirReading<MemoirEntry<ExpenseCategoryRecord>>
    do throws(StoreError) {
      reading = try ExpenseCategoryRecord.read(key: .expenseCategory(key), in: transaction)
    } catch {
      throw FinanceError(error)
    }
    var record: ExpenseCategoryRecord
    switch reading {
    case .readable(let entry):
      guard entry.record.essential != essential else { return nil }
      record = entry.record
    case .absent:
      guard essential != nil else { return nil }
      record = ExpenseCategoryRecord(key: key, label: label)
    case .unreadable:
      throw .unreadable(MemoirKey.expenseCategory(key).ref)
    }
    record.essential = essential
    let written = record
    do throws(MemoirRecordError) {
      if case .absent = reading {
        try written.createOmitting([.archived], in: &transaction)
      } else {
        try ExpenseCategoryRecord.edit(written.ref, in: &transaction) { $0.essential = essential }
      }
    } catch {
      throw FinanceError(error)
    }
    return written
  }
}
