public enum BillingFrequency: Sendable, Hashable {
  case weekly
  case monthly
  case quarterly
  case yearly
  /// Without an interval the cycle is 30 days. Like the reference, an interval of zero or less does not move the due date forward.
  case custom(intervalDays: Int?)
}

public struct SubscriptionCycle: Sendable, Hashable {
  public static let defaultCustomIntervalDays = 30

  public let frequency: BillingFrequency
  public let billingDay: Int

  public init(frequency: BillingFrequency, billingDay: Int) throws(CalendarError) {
    guard (1...31).contains(billingDay) else { throw .billingDayOutOfRange(billingDay) }
    self.frequency = frequency
    self.billingDay = billingDay
  }

  /// The month-based frequencies rebuild the date from `billingDay` every cycle, so a due date clamped to a short month returns to the billing day.
  public func advanceDueDate(from date: LocalDate) -> LocalDate? {
    switch frequency {
    case .weekly: date.adding(days: 7)
    case .monthly: rebased(date, months: 1)
    case .quarterly: rebased(date, months: 3)
    case .yearly: rebased(date, months: 12)
    case .custom(let intervalDays): date.adding(days: intervalDays ?? Self.defaultCustomIntervalDays)
    }
  }

  private func rebased(_ date: LocalDate, months: Int) -> LocalDate? {
    LocalDate.clampedToMonthEnd(monthIndex: date.monthIndex + months, day: billingDay)
  }
}
