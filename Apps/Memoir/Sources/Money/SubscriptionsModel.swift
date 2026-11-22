import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// A subscription's record writes with their commands, in the caller's main-store write: the record carries the owner's words and terms, the command
/// names it by id (`subscription.create`, `.update`, `.delete`), and the reference's checks on the terms run before either is written.
nonisolated enum SubscriptionWrites {
  static func create(_ subscription: SubscriptionRecord, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws {
    try issuer.issue(.subscriptionCreate(RecordReference(id: subscription.id)), content: subscription, in: &transaction)
    try subscription.create(in: &transaction)
  }

  /// `false`, writing nothing, when the change moves no field.
  @discardableResult
  static func update(_ id: UUID, issuer: CommandIssuer, in transaction: inout WriteTransaction, _ change: (inout SubscriptionRecord) -> Void) throws -> Bool {
    let current = try present(id, in: transaction)
    var edited = current
    change(&edited)
    guard edited != current else { return false }
    let updated = edited
    try issuer.issue(.subscriptionUpdate(RecordReference(id: id)), content: updated, in: &transaction)
    try SubscriptionRecord.edit(id: id, in: &transaction) { $0 = updated }
    return true
  }

  /// Clears the note, the owner's words, as `ExpenseEdits.delete` clears an expense's, and marks the subscription removed.
  static func delete(_ id: UUID, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws {
    _ = try present(id, in: transaction)
    try SubscriptionRecord.edit(id: id, in: &transaction) { $0.note = nil }
    try SubscriptionRecord.remove(SubscriptionRecord.ref(id), in: &transaction)
    try issuer.issue(.subscriptionDelete(RecordReference(id: id)), in: &transaction)
  }

  /// memoir-web `FIN_004` when the subscription is gone.
  private static func present(_ id: UUID, in transaction: borrowing WriteTransaction) throws -> SubscriptionRecord {
    switch try SubscriptionRecord.read(id: id, in: transaction) {
    case .readable(let entry) where !entry.isRemoved: return entry.record
    case .readable, .absent: throw FinanceError.subscriptionAbsent(id)
    case .unreadable: throw FinanceError.unreadable(SubscriptionRecord.ref(id))
    }
  }
}

/// memoir-web `SubscriptionsScreen`: every subscription by next due date with its due state and monthly cost, the coming month's charges and the days
/// two renew together; a due cycle is confirmed by hand and a subscription paused or resumed.
@MainActor
@Observable
final class SubscriptionsModel {
  let overview = MoneyFeed<SubscriptionsOverview?>()
  private(set) var working: Set<UUID> = []
  private(set) var failure: PresentedError?
  private(set) var notice: String?
  @ObservationIgnored let context: MemoirScreenContext

  init(context: MemoirScreenContext) {
    self.context = context
  }

  func run() async {
    defer { overview.stop() }
    var followed: LocalDate?
    do {
      for try await today in context.observeToday() where today.date != followed {
        followed = today.date
        let stores = context.stores
        let date = today.date
        overview.follow { MoneyReads.observeSubscriptions(in: stores, today: date) }
      }
    } catch {
      overview.fail(error)
    }
  }

  func name(of id: UUID) -> String? {
    overview.state.value??.items.first { $0.subscription.id == id }?.subscription.name
  }

  /// Confirms the cycle due on `nextDue`: the cycle's expense is written once, however many devices confirm it.
  func confirm(_ standing: SubscriptionStanding, locale: Locale) async {
    let subscription = standing.subscription
    let confirmation = CycleConfirmation(subscription: subscription.id, billingDate: standing.nextDue)
    let wrote = await perform(subscription.id) { issuer, transaction in try issuer.confirmCycle(confirmation, in: &transaction).expense != nil }
    guard let wrote else { return }
    let day = MoneyDates.text(standing.nextDue, locale: locale)
    notice =
      wrote
      ? String(localized: "\(subscription.name) confirmed for \(day).", table: "Money")
      : String(localized: "Already confirmed for this cycle.", table: "Money")
  }

  func setActive(_ id: UUID, _ active: Bool) async {
    let changed = await perform(id) { issuer, transaction in try SubscriptionWrites.update(id, issuer: issuer, in: &transaction) { $0.active = active } }
    guard changed != nil else { return }
    notice = active ? String(localized: "Subscription resumed.", table: "Money") : String(localized: "Subscription paused.", table: "Money")
  }

  func dismissNotice() {
    notice = nil
    failure = nil
  }

  private func perform<T: Sendable>(_ id: UUID, _ body: @escaping @Sendable (CommandIssuer, inout WriteTransaction) throws -> T) async -> T? {
    guard !working.contains(id) else { return nil }
    working.insert(id)
    failure = nil
    notice = nil
    defer { working.remove(id) }
    do {
      return try await context.writer.write(body)
    } catch {
      failure = WritingErrors.presented(error)
      return nil
    }
  }
}
