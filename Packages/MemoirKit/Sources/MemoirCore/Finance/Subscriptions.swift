import Foundation
import ShadowCore
import ShadowStore

/// A subscription's validated cycle. A custom interval of zero or less is refused, where the reference stops the due date from moving.
public struct BillingTerms: Hashable, Sendable {
  public let frequency: SubscriptionFrequency
  public let cycle: SubscriptionCycle

  public init(frequency: StoredChoice<SubscriptionFrequency>, customIntervalDays: Int?, billingDay: Int) throws(FinanceError) {
    guard let known = frequency.known else { throw .unknownFrequency(frequency.rawValue) }
    let billing: BillingFrequency
    switch known {
    case .weekly: billing = .weekly
    case .monthly: billing = .monthly
    case .quarterly: billing = .quarterly
    case .yearly: billing = .yearly
    case .custom:
      if let days = customIntervalDays, days <= 0 { throw .customIntervalNotPositive(days) }
      billing = .custom(intervalDays: customIntervalDays)
    }
    do throws(CalendarError) {
      cycle = try SubscriptionCycle(frequency: billing, billingDay: billingDay)
    } catch {
      throw .billingDayOutOfRange(billingDay)
    }
    self.frequency = known
  }

  public init(_ subscription: SubscriptionRecord) throws(FinanceError) {
    try self.init(frequency: subscription.frequency, customIntervalDays: subscription.customIntervalDays, billingDay: subscription.billingDay)
  }

  /// apps/memoir-server/src/modules/finance/finance-commands.service.ts:100-106, in integer division that truncates toward zero as `BigInt` does.
  public func monthlyEquivalentMinor(of amountMinor: Int64) throws(FinanceError) -> Int64 {
    let amount = Int128(amountMinor)
    let monthly: Int128 =
      switch cycle.frequency {
      case .weekly: amount * 52 / 12
      case .monthly: amount
      case .quarterly: amount / 3
      case .yearly: amount / 12
      case .custom(let days): amount * 30 / Int128(days ?? SubscriptionCycle.defaultCustomIntervalDays)
      }
    guard let minor = Int64(exactly: monthly) else { throw .overflow }
    return minor
  }

  public func nextDueDate(after date: LocalDate) throws(FinanceError) -> LocalDate {
    guard let next = cycle.advanceDueDate(from: date) else { throw .dateOutOfRange }
    return next
  }
}

extension SubscriptionRecord {
  public func monthlyEquivalent() throws(FinanceError) -> MoneyAmount {
    MoneyAmount(amountMinor: try BillingTerms(self).monthlyEquivalentMinor(of: amountMinor), currency: currency)
  }
}

/// The payload of a `subscription.confirmCycle` command, which the command layer parses; finance reads only these two values.
public struct CycleConfirmation: Hashable, Sendable {
  public let subscription: UUID
  public let billingDate: LocalDate

  public init(subscription: UUID, billingDate: LocalDate) {
    self.subscription = subscription
    self.billingDate = billingDate
  }
}

/// Derived from the owner's anchor date and the confirmed cycles, never stored. The latest confirmed billing date wins whatever order the confirmations
/// arrive in; one before the anchor (the owner moved the due date forward) leaves the anchor as the next due date. Unlike the reference's
/// `subscription.update`, which sets `nextDueDate` outright, an anchor moved to or before the latest confirmed billing date is ignored and the next due
/// date stays the cycle after that billing date.
public struct SubscriptionSchedule: Hashable, Sendable {
  public let nextDue: LocalDate
  public let lastConfirmed: LocalDate?

  public init(subscription: SubscriptionRecord, confirmations: some Sequence<CycleConfirmation>) throws(FinanceError) {
    let terms = try BillingTerms(subscription)
    let latest = confirmations.filter { $0.subscription == subscription.id }.map(\.billingDate).max()
    lastConfirmed = latest
    guard let latest, latest >= subscription.anchorOn else {
      nextDue = subscription.anchorOn
      return
    }
    nextDue = try terms.nextDueDate(after: latest)
  }
}

public enum SubscriptionCycles {
  public static let expenseDomain = "com.shadow.library.memoircore.subscription-cycle-expense"

  /// The same on every device, so two devices confirming one cycle write one expense.
  public static func expenseID(for confirmation: CycleConfirmation) -> UUID {
    derivedID(expenseDomain, "\(confirmation.subscription.lowercasedString)|\(confirmation.billingDate.isoString)")
  }

  public static func expense(for confirmation: CycleConfirmation, of subscription: SubscriptionRecord, loggedAtMillis: Int64) -> ExpenseRecord {
    let seed = ExpenseCycleSeed(subscription: subscription.id, amountMinor: subscription.amountMinor, occurredOn: confirmation.billingDate, category: subscription.category)
    return ExpenseRecord(
      id: expenseID(for: confirmation), amountMinor: seed.amountMinor, currency: subscription.currency, occurredOn: seed.occurredOn, category: seed.category,
      cycle: seed, loggedAtMillis: loggedAtMillis)
  }

  /// Writes the cycle's expense in the transaction that appends the confirm command, with its rate captured. Returns `nil` when this device already
  /// holds the cycle's expense in any state, so confirming again here never re-inserts an expense the owner deleted (the reference re-inserts it).
  /// Unlike the reference, the expense does not copy the subscription's note: the seed is first-writer and would keep it past the expense's deletion.
  /// A device that has not received the expense yet writes it again under the same derived id, but only its first-writer fields (the seed, currency,
  /// rate and logging time) and no removal, so whatever its clock it neither restores an expense the owner deleted elsewhere nor reverts an edit made
  /// there; two seeds of one cycle settle on the earlier. It purges no change record: any it holds for the expense were written elsewhere.
  @discardableResult
  public static func confirm(_ confirmation: CycleConfirmation, loggedAtMillis: Int64, in transaction: inout WriteTransaction) throws(FinanceError) -> ExpenseRecord? {
    let reading: MemoirReading<MemoirEntry<SubscriptionRecord>>
    let existing: EntityState?
    let expense: EntityRef = ExpenseRecord.ref(expenseID(for: confirmation))
    do throws(StoreError) {
      reading = try SubscriptionRecord.read(id: confirmation.subscription, in: transaction)
      existing = try transaction.state(of: expense, scope: .vault)
    } catch {
      throw FinanceError(error)
    }
    let subscription: SubscriptionRecord
    switch reading {
    case .absent: throw .subscriptionAbsent(confirmation.subscription)
    case .unreadable: throw .unreadable(SubscriptionRecord.ref(confirmation.subscription))
    case .readable(let entry):
      guard !entry.isRemoved else { throw .subscriptionAbsent(confirmation.subscription) }
      subscription = entry.record
    }
    _ = try BillingTerms(subscription)
    guard existing == nil else { return nil }
    let written = try self.expense(for: confirmation, of: subscription, loggedAtMillis: loggedAtMillis).capturingVaultRate(from: transaction)
    do throws(MemoirRecordError) {
      try written.createKeepingRemovalAndEdits(in: &transaction)
    } catch {
      throw FinanceError(error)
    }
    return written
  }
}
