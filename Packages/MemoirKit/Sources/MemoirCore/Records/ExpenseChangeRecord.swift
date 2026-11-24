import Foundation
import ShadowCore
import ShadowStore

/// One field an expense edit moved, from and to; memoir-web `ExpenseAuditChange` (`lib/data/finance.types.ts:120-126`) without the currency, which an
/// expense keeps from its first write, and with the rate the owner typed, the budget, the savings draw and the goal, which the reference does not have.
public enum ExpenseFieldChange: Sendable, Hashable {
  case amount(from: Int64, to: Int64)
  case occurredOn(from: LocalDate, to: LocalDate)
  case category(from: CategoryKey, to: CategoryKey)
  case merchant(from: String?, to: String?)
  case note(from: String?, to: String?)
  case manualRate(from: ManualRate?, to: ManualRate?)
  case budget(from: UUID?, to: UUID?)
  case fromSavings(from: Int64?, to: Int64?)
  case goal(from: UUID?, to: UUID?)

  /// memoir-web `expenseChanges` (`lib/data/finance.rules.ts:357-367`): the owner-visible fields that moved, in its order; an empty text is no text.
  public static func changes(from before: ExpenseRecord, to after: ExpenseRecord) -> [ExpenseFieldChange] {
    var changes = [ExpenseFieldChange]()
    if before.amountMinor != after.amountMinor { changes.append(.amount(from: before.amountMinor, to: after.amountMinor)) }
    if before.occurredOn != after.occurredOn { changes.append(.occurredOn(from: before.occurredOn, to: after.occurredOn)) }
    if before.category != after.category { changes.append(.category(from: before.category, to: after.category)) }
    if text(before.note) != text(after.note) { changes.append(.note(from: text(before.note), to: text(after.note))) }
    if text(before.merchant) != text(after.merchant) { changes.append(.merchant(from: text(before.merchant), to: text(after.merchant))) }
    if before.manualRate != after.manualRate { changes.append(.manualRate(from: before.manualRate, to: after.manualRate)) }
    if before.budget != after.budget { changes.append(.budget(from: before.budget, to: after.budget)) }
    if before.fromSavingsMinor != after.fromSavingsMinor { changes.append(.fromSavings(from: before.fromSavingsMinor, to: after.fromSavingsMinor)) }
    if before.goal != after.goal { changes.append(.goal(from: before.goal, to: after.goal)) }
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
    case manualRate = "manual_rate"
    case budget
    case fromSavings = "from_savings_minor"
    case goal
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
          case .manualRate: return .manualRate(from: try reader.optional(.from), to: try reader.optional(.to))
          case .budget: return .budget(from: try reader.optional(.from), to: try reader.optional(.to))
          case .fromSavings: return .fromSavings(from: try reader.optional(.from), to: try reader.optional(.to))
          case .goal: return .goal(from: try reader.optional(.from), to: try reader.optional(.to))
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
    case .manualRate(let from, let to): Self.put(&members, .manualRate, from, to)
    case .budget(let from, let to): Self.put(&members, .budget, from, to)
    case .fromSavings(let from, let to): Self.put(&members, .fromSavings, from, to)
    case .goal(let from, let to): Self.put(&members, .goal, from, to)
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
/// Appended, so two devices editing one expense at once both keep their change in the history, whichever edit the expense's registers kept. `reason`
/// names why an edit was made when it was more than a correction.
public struct ExpenseChangeRecord: AppendedMemoirRecord {
  public static let kind = MemoirKind.expenseChange

  public let command: UUID
  public let expense: UUID
  public let changes: [ExpenseFieldChange]
  public let reason: StoredChoice<ExpenseChangeReason>?

  public init(command: UUID, expense: UUID, changes: [ExpenseFieldChange], reason: StoredChoice<ExpenseChangeReason>? = nil) {
    self.command = command
    self.expense = expense
    self.changes = changes
    self.reason = reason
  }

  public init(id: UUID, reading reader: MemberReader<ExpenseChangeMember>) throws(MemoirUnreadable) {
    self.init(command: id, expense: try reader.required(.expense), changes: try reader.required(.changes), reason: try reader.optional(.reason))
  }

  public var id: UUID { command }

  public var members: RecordMembers<ExpenseChangeMember> {
    var members = RecordMembers<ExpenseChangeMember>()
    members.put(.expense, expense)
    members.put(.changes, changes)
    members.put(.reason, reason)
    return members
  }
}

public enum ExpenseChangeReason: String, CaseIterable, Hashable, Sendable {
  case refund
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
