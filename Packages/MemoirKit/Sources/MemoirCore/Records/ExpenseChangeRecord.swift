import Foundation
import ShadowCore
import ShadowStore

/// One field an expense edit moved, from and to; memoir-web `ExpenseAuditChange` (`lib/data/finance.types.ts:120-126`) without the currency, which an
/// expense keeps from its first write.
public enum ExpenseFieldChange: Sendable, Hashable {
  case amount(from: Int64, to: Int64)
  case occurredOn(from: LocalDate, to: LocalDate)
  case category(from: CategoryKey, to: CategoryKey)
  case merchant(from: String?, to: String?)
  case note(from: String?, to: String?)

  /// memoir-web `expenseChanges` (`lib/data/finance.rules.ts:357-367`): the owner-visible fields that moved, in its order; an empty text is no text.
  public static func changes(from before: ExpenseRecord, to after: ExpenseRecord) -> [ExpenseFieldChange] {
    var changes = [ExpenseFieldChange]()
    if before.amountMinor != after.amountMinor { changes.append(.amount(from: before.amountMinor, to: after.amountMinor)) }
    if before.occurredOn != after.occurredOn { changes.append(.occurredOn(from: before.occurredOn, to: after.occurredOn)) }
    if before.category != after.category { changes.append(.category(from: before.category, to: after.category)) }
    if text(before.note) != text(after.note) { changes.append(.note(from: text(before.note), to: text(after.note))) }
    if text(before.merchant) != text(after.merchant) { changes.append(.merchant(from: text(before.merchant), to: text(after.merchant))) }
    return changes
  }

  private static func text(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

extension ExpenseFieldChange: StoredValue {
  private enum Field: String {
    case amount = "amount_minor"
    case occurredOn = "occurred_on"
    case category
    case merchant
    case note
  }

  public init?(stored: JSONValue) {
    guard
      let change = MemberReader<ExpenseFieldChangeMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) -> ExpenseFieldChange in
          let name: String = try reader.required(.field)
          switch Field(rawValue: name) {
          case .amount: return .amount(from: try reader.required(.from), to: try reader.required(.to))
          case .occurredOn: return .occurredOn(from: try reader.required(.from), to: try reader.required(.to))
          case .category: return .category(from: try reader.required(.from), to: try reader.required(.to))
          case .merchant: return .merchant(from: try reader.optional(.from), to: try reader.optional(.to))
          case .note: return .note(from: try reader.optional(.from), to: try reader.optional(.to))
          case nil: throw .invalid(field: ExpenseFieldChangeMember.field.rawValue)
          }
        })
    else { return nil }
    self = change
  }

  public var stored: JSONValue {
    var members = RecordMembers<ExpenseFieldChangeMember>()
    switch self {
    case .amount(let from, let to): Self.put(&members, .amount, from, to)
    case .occurredOn(let from, let to): Self.put(&members, .occurredOn, from, to)
    case .category(let from, let to): Self.put(&members, .category, from, to)
    case .merchant(let from, let to): Self.put(&members, .merchant, from, to)
    case .note(let from, let to): Self.put(&members, .note, from, to)
    }
    return members.json
  }

  private static func put<Value: StoredValue>(_ members: inout RecordMembers<ExpenseFieldChangeMember>, _ field: Field, _ from: Value?, _ to: Value?) {
    members.put(.field, field.rawValue)
    members.put(.from, from)
    members.put(.to, to)
  }
}

/// What an `expense.update` changed, kept under the command's own id as a reason note is, so the command's payload stays free of the owner's values.
/// Appended, so two devices editing one expense at once both keep their change in the history, whichever edit the expense's registers kept.
public struct ExpenseChangeRecord: AppendedMemoirRecord {
  public static let kind = MemoirKind.expenseChange

  public let command: UUID
  public let expense: UUID
  public let changes: [ExpenseFieldChange]

  public init(command: UUID, expense: UUID, changes: [ExpenseFieldChange]) {
    self.command = command
    self.expense = expense
    self.changes = changes
  }

  public init(id: UUID, reading reader: MemberReader<ExpenseChangeMember>) throws(MemoirUnreadable) {
    self.init(command: id, expense: try reader.required(.expense), changes: try reader.required(.changes))
  }

  public var id: UUID { command }

  public var members: RecordMembers<ExpenseChangeMember> {
    var members = RecordMembers<ExpenseChangeMember>()
    members.put(.expense, expense)
    members.put(.changes, changes)
    return members
  }
}

extension ExpenseChangeRecord {
  /// Purges every change record of `expense`: they hold its old notes and merchants, so they go when it is deleted or created again, as the reference's
  /// `ExpenseAuditRepository.removeForExpense` removes its audit rows. It matches the stored `expense` member, so a newer device's record this version
  /// cannot otherwise read is purged too.
  @discardableResult
  static func purge(expense: UUID, in transaction: inout WriteTransaction) throws(MemoirRecordError) -> Int {
    do throws(StoreError) {
      var purged = 0
      for (ref, state) in try transaction.states(ofKind: kind.entityKind, scope: .vault) {
        guard case .appended(let stored) = state, let member = stored.item[ExpenseChangeMember.expense.rawValue], UUID(stored: member) == expense else { continue }
        _ = try transaction.purge(ref)
        purged += 1
      }
      return purged
    } catch {
      throw .store(error)
    }
  }
}
