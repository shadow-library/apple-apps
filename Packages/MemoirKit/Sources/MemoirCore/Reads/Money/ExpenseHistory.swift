import Foundation
import ShadowStore

/// memoir-web `ExpenseAuditAction` (`lib/data/finance.types.ts:118`), read from the commands that name the expense.
public enum ExpenseHistoryAction: Sendable, Hashable {
  case created(source: ExpenseSource)
  /// The fields the edit moved, or `nil` when the edit was made without its change record (an app before registry v4).
  case updated(changes: [ExpenseFieldChange]?)
  case deleted
  case cycleConfirmed(subscription: UUID)
  case receiptScanned
}

public struct ExpenseHistoryEntry: Sendable, Hashable {
  public let command: UUID
  public let instantMillis: Int64
  public let utcOffsetMinutes: Int
  public let issuedOn: LocalDate
  public let action: ExpenseHistoryAction
}

public struct ExpenseHistory: Sendable, Equatable {
  public let expense: MemoirReading<MemoirEntry<ExpenseRecord>>
  /// Newest first by the instant the command was issued, then by command id, as memoir-web's `sortAuditNewestFirst` (`finance.rules.ts:343-351`).
  /// The history starts again at the latest `expense.create` of the id (or the first confirmation of the cycle that wrote it), as the reference clears an
  /// expense's audit when it is created.
  public let entries: [ExpenseHistoryEntry]
  /// Commands this version cannot read; one of them may name the expense.
  public let unreadableCommands: Int

  static func read(_ id: UUID, in transaction: ReadTransaction) throws(StoreError) -> ExpenseHistory {
    let expense = try ExpenseRecord.read(id: id, in: transaction)
    let receipt = expense.entry?.record.receipt
    var entries = [ExpenseHistoryEntry]()
    var confirmed = false
    let commands = try ReadSources.commands(in: transaction)
    for (command, body) in commands.commands {
      let action: ExpenseHistoryAction
      switch body {
      case .expenseCreate(let creation) where creation.id == id:
        entries.removeAll()
        action = .created(source: creation.source)
      case .expenseUpdate(let reference) where reference.id == id:
        let change = try ExpenseChangeRecord.read(id: command.id, in: transaction).entry?.record
        action = .updated(changes: change.flatMap { $0.expense == id ? $0.changes : nil })
      case .expenseDelete(let reference) where reference.id == id:
        action = .deleted
      case .subscriptionConfirmCycle(let confirmation) where SubscriptionCycles.expenseID(for: confirmation) == id:
        if !confirmed { entries.removeAll() }
        confirmed = true
        action = .cycleConfirmed(subscription: confirmation.subscription)
      case .receiptScan(let scan) where receipt != nil && scan.receiptId == receipt:
        action = .receiptScanned
      default:
        continue
      }
      entries.append(
        ExpenseHistoryEntry(
          command: command.id, instantMillis: command.instantMillis, utcOffsetMinutes: command.utcOffsetMinutes, issuedOn: command.issuedOn, action: action))
    }
    entries.sort { first, second in
      first.instantMillis != second.instantMillis ? first.instantMillis > second.instantMillis : first.command.uuidString > second.command.uuidString
    }
    return ExpenseHistory(expense: expense, entries: entries, unreadableCommands: commands.unreadable)
  }
}
