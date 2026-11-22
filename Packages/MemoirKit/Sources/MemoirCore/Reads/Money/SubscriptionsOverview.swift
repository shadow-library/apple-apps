import Foundation

/// memoir-web `SubscriptionDueState` (`lib/data/finance.types.ts:156`); never stored.
public enum SubscriptionDueState: String, Sendable, CaseIterable {
  case none
  case upcoming
  case due
  case overdue
}

extension SubscriptionReminderLead {
  /// memoir-web `REMINDER_LEAD_DAYS` (`lib/data/finance.rules.ts:31-37`).
  public var days: Int {
    switch self {
    case .onDay: 0
    case .oneDay: 1
    case .twoDays: 2
    case .threeDays: 3
    case .oneWeek: 7
    }
  }
}

public struct SubscriptionStanding: Sendable, Equatable {
  /// memoir-web `DEFAULT_UPCOMING_WINDOW_DAYS` (`finance.rules.ts:29`): without a reminder a renewal shows as upcoming a week ahead.
  public static let defaultUpcomingWindowDays = 7

  public let subscription: SubscriptionRecord
  public let nextDue: LocalDate
  public let lastConfirmed: LocalDate?
  public let daysUntilDue: Int
  public let dueState: SubscriptionDueState
  /// The days before the due date a renewal counts as upcoming: the reminder's lead when a reminder is on and its lead is known, else seven.
  public let upcomingWindowDays: Int
  /// The day the reminder fires, for an active subscription with a reminder on whose cycle is not yet confirmed.
  public let reminderOn: LocalDate?
  public let monthlyEquivalent: MoneyAmount
  public let monthlyInHome: HomeAmount

  init(_ subscription: SubscriptionRecord, schedule: SubscriptionSchedule, today: LocalDate, home: CurrencyCode, rates: [CurrencyCode: DecimalText])
    throws(FinanceError)
  {
    self.subscription = subscription
    nextDue = schedule.nextDue
    lastConfirmed = schedule.lastConfirmed
    daysUntilDue = schedule.nextDue.days(since: today)
    let lead = subscription.reminderEnabled ? subscription.reminderLead.known?.days : nil
    upcomingWindowDays = lead ?? Self.defaultUpcomingWindowDays
    let confirmed = schedule.lastConfirmed.map { $0 >= schedule.nextDue } ?? false
    dueState = Self.dueState(active: subscription.active, confirmed: confirmed, daysUntilDue: daysUntilDue, window: upcomingWindowDays)
    reminderOn = subscription.active && !confirmed ? lead.flatMap { schedule.nextDue.adding(days: -$0) } : nil
    monthlyEquivalent = try subscription.monthlyEquivalent()
    monthlyInHome = HomeConverter.convert(monthlyEquivalent, home: home, rate: rates[subscription.currency])
  }

  /// memoir-web `deriveDueState` (`finance.rules.ts:141-149`): a cycle already confirmed is `none` however far past its date.
  static func dueState(active: Bool, confirmed: Bool, daysUntilDue: Int, window: Int) -> SubscriptionDueState {
    guard active, !confirmed else { return .none }
    if daysUntilDue < 0 { return .overdue }
    if daysUntilDue == 0 { return .due }
    return daysUntilDue <= window ? .upcoming : .none
  }
}

/// An active subscription's next charge within the coming 30 days.
public struct UpcomingCharge: Sendable, Hashable {
  public let subscription: UUID
  public let dueOn: LocalDate
  public let amount: MoneyAmount
  public let inHome: HomeAmount
}

/// memoir-web `SubscriptionCollision` (`finance.types.ts:325-332`): a day on which more than one active subscription renews, shown as information.
public struct SubscriptionCollision: Sendable, Hashable {
  public let date: LocalDate
  public let subscriptions: [UUID]
  /// The charges that converted, in the home currency; `nil` when none did.
  public let totalMinor: Int64?
  /// The charges that did not convert, in their own currency, never folded into the total as zero.
  public let unconverted: [MoneyAmount]
}

public struct SubscriptionTotals: Sendable, Hashable {
  public static let empty = SubscriptionTotals(activeCount: 0, monthlyMinor: 0, yearlyMinor: 0, pending: .none)

  public let activeCount: Int
  /// The active subscriptions' monthly equivalents that converted, in the home currency.
  public let monthlyMinor: Int64
  /// memoir-web `yearlyTotalMinor` (`finance.provider.ts:568`): twelve times the monthly total.
  public let yearlyMinor: Int64
  public let pending: PendingConversions
}

/// memoir-web `SubscriptionHighlight` (`finance.provider.ts:479-485`): the oldest renewal waiting to be confirmed, with how many wait, or else the next one.
public enum SubscriptionHighlight: Sendable, Hashable {
  case overdue(subscription: UUID, dueOn: LocalDate, count: Int)
  case next(subscription: UUID, dueOn: LocalDate)
}

public struct SubscriptionsOverview: Sendable, Equatable {
  public static let upcomingWindowDays = 30

  public let home: CurrencyCode
  /// Every subscription, active or not, by next due date.
  public let items: [SubscriptionStanding]
  public let totals: SubscriptionTotals
  public let upcoming: [UpcomingCharge]
  public let collisions: [SubscriptionCollision]
  public let highlight: SubscriptionHighlight?
  /// Subscriptions whose terms this version cannot read (a frequency from a newer app), left out of everything else.
  public let unreadable: Int

  /// `nil` until the vault has its settings. memoir-web `financeSubscriptionsView` (`finance.provider.ts:527-574`); a subscription's monthly equivalent
  /// converts at the newest recorded rate of its currency on or before today, where the reference takes the newest rate an expense locked.
  public static func make(_ book: MoneyBook, today: LocalDate) throws(FinanceError) -> SubscriptionsOverview? {
    guard let home = book.home else { return nil }
    let rates = book.latestRates(home: home, today: today)
    var items = [SubscriptionStanding]()
    var unreadable = 0
    for subscription in book.subscriptions {
      do throws(FinanceError) {
        let schedule = try SubscriptionSchedule(subscription: subscription, confirmations: book.confirmations)
        items.append(try SubscriptionStanding(subscription, schedule: schedule, today: today, home: home, rates: rates))
      } catch {
        if error == .overflow { throw error }
        unreadable += 1
      }
    }
    items.sort { ($0.nextDue, $0.subscription.id.uuidString) < ($1.nextDue, $1.subscription.id.uuidString) }
    let active = items.filter(\.subscription.active)
    let monthly = try HomeTotal(home: home, amounts: active.map { ($0.subscription.currency, $0.monthlyInHome) })
    let (yearly, overflow) = monthly.totalMinor.multipliedReportingOverflow(by: 12)
    guard !overflow else { throw .overflow }
    let upcoming = active.filter { (0...upcomingWindowDays).contains($0.daysUntilDue) }.map { standing in
      let amount = MoneyAmount(amountMinor: standing.subscription.amountMinor, currency: standing.subscription.currency)
      return UpcomingCharge(
        subscription: standing.subscription.id, dueOn: standing.nextDue, amount: amount,
        inHome: HomeConverter.convert(amount, home: home, rate: rates[amount.currency]))
    }
    return SubscriptionsOverview(
      home: home, items: items, totals: SubscriptionTotals(activeCount: active.count, monthlyMinor: monthly.totalMinor, yearlyMinor: yearly, pending: monthly.pending),
      upcoming: upcoming, collisions: try collisions(upcoming, home: home), highlight: highlight(active, today: today), unreadable: unreadable + book.unreadable)
  }

  private static func collisions(_ upcoming: [UpcomingCharge], home: CurrencyCode) throws(FinanceError) -> [SubscriptionCollision] {
    let byDate = Dictionary(grouping: upcoming, by: \.dueOn)
    var collisions = [SubscriptionCollision]()
    for date in byDate.keys.sorted() {
      guard let charges = byDate[date], charges.count > 1 else { continue }
      let total = try HomeTotal(home: home, amounts: charges.map { ($0.amount.currency, $0.inHome) })
      let converted = charges.contains { $0.inHome.minor != nil }
      collisions.append(
        SubscriptionCollision(
          date: date, subscriptions: charges.map(\.subscription), totalMinor: converted ? total.totalMinor : nil,
          unconverted: charges.filter { $0.inHome.minor == nil }.map(\.amount)))
    }
    return collisions
  }

  private static func highlight(_ active: [SubscriptionStanding], today: LocalDate) -> SubscriptionHighlight? {
    let overdue = active.filter { $0.dueState == .overdue }
    if let oldest = overdue.first { return .overdue(subscription: oldest.subscription.id, dueOn: oldest.nextDue, count: overdue.count) }
    let next = active.first { standing in standing.nextDue >= today && !(standing.lastConfirmed.map { $0 >= standing.nextDue } ?? false) }
    return next.map { .next(subscription: $0.subscription.id, dueOn: $0.nextDue) }
  }
}
