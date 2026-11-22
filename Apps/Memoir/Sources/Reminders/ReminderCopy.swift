import Foundation
import MemoirCore
import ShadowAppShell

/// A reminder's words, written in the owner's locale when it is scheduled. A minute of the day or a `LocalDate` has no zone, so each is placed at UTC
/// and formatted there.
nonisolated enum ReminderCopy {
  static let threadPrefix = "\(AppIdentity.memoir.id).reminders."

  private static let utc = TimeZone(identifier: "UTC") ?? .gmt

  static func request(for reminder: Reminder, locale: Locale = .current) -> ReminderRequest {
    switch reminder.content {
    case .quest(let quest):
      ReminderRequest(
        identifier: reminder.identifier, title: title(quest.name, fallback: String(localized: "Quest reminder", table: "Reminders", locale: locale)),
        body: questBody(startMinute: quest.startMinute, leadMinutes: quest.leadMinutes, isRescheduled: quest.isRescheduled, locale: locale),
        fireAt: reminder.fireAt, thread: threadPrefix + ReminderKind.quest.rawValue,
        userInfo: userInfo(.quest, record: quest.quest, date: quest.date))
    case .subscription(let subscription):
      ReminderRequest(
        identifier: reminder.identifier,
        title: title(subscription.name, fallback: String(localized: "Subscription reminder", table: "Reminders", locale: locale)),
        body: subscriptionBody(dueOn: subscription.dueOn, lead: subscription.lead, amount: subscription.amount, locale: locale),
        fireAt: reminder.fireAt, thread: threadPrefix + ReminderKind.subscription.rawValue,
        userInfo: userInfo(.subscription, record: subscription.subscription, date: subscription.dueOn))
    }
  }

  /// A quest without a time of day is reminded at the start of the wake window with no lead.
  static func questBody(startMinute: Int?, leadMinutes: Int, isRescheduled: Bool, locale: Locale) -> String {
    guard let startMinute else { return String(localized: "On your plan for today.", table: "Reminders", locale: locale) }
    let time = time(minuteOfDay: startMinute, locale: locale)
    guard leadMinutes > 0 else {
      return isRescheduled
        ? String(localized: "Starts now, at \(time), the time you moved it to.", table: "Reminders", locale: locale)
        : String(localized: "Starts now, at \(time).", table: "Reminders", locale: locale)
    }
    let lead = lead(minutes: leadMinutes, locale: locale)
    return isRescheduled
      ? String(localized: "Starts in \(lead), at \(time), the time you moved it to.", table: "Reminders", locale: locale)
      : String(localized: "Starts in \(lead), at \(time).", table: "Reminders", locale: locale)
  }

  /// The reminder fires on the day its lead names, so the lead alone says how far off the charge is.
  static func subscriptionBody(dueOn: LocalDate, lead: SubscriptionReminderLead, amount: MoneyAmount, locale: Locale) -> String {
    guard let money = Self.amount(amount, locale: locale) else {
      switch lead {
      case .onDay: return String(localized: "Renews today.", table: "Reminders", locale: locale)
      case .oneDay: return String(localized: "Renews tomorrow.", table: "Reminders", locale: locale)
      case .twoDays, .threeDays, .oneWeek:
        return String(localized: "Renews on \(day(dueOn, locale: locale)).", table: "Reminders", locale: locale)
      }
    }
    switch lead {
    case .onDay: return String(localized: "Renews today for \(money).", table: "Reminders", locale: locale)
    case .oneDay: return String(localized: "Renews tomorrow for \(money).", table: "Reminders", locale: locale)
    case .twoDays, .threeDays, .oneWeek:
      return String(localized: "Renews on \(day(dueOn, locale: locale)) for \(money).", table: "Reminders", locale: locale)
    }
  }

  /// Exact from minor units with the currency's ISO 4217 exponent; nil for a currency this version does not know, whose exponent it cannot tell.
  static func amount(_ amount: MoneyAmount, locale: Locale) -> String? {
    guard let exponent = try? ISO4217.exponent(of: amount.currency) else { return nil }
    let value = Decimal(sign: amount.amountMinor < 0 ? .minus : .plus, exponent: -exponent, significand: Decimal(amount.amountMinor.magnitude))
    return value.formatted(.currency(code: amount.currency.code).locale(locale).precision(.fractionLength(exponent)))
  }

  static func time(minuteOfDay minute: Int, locale: Locale) -> String {
    Date(timeIntervalSince1970: TimeInterval(minute * 60)).formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: utc))
  }

  static func lead(minutes: Int, locale: Locale) -> String {
    Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide).locale(locale))
  }

  static func day(_ date: LocalDate, locale: Locale) -> String {
    Date(timeIntervalSince1970: TimeInterval(date.daysSinceEpoch) * 86_400).formatted(
      Date.FormatStyle(locale: locale, timeZone: utc).weekday(.wide).day().month(.wide))
  }

  private static func title(_ name: String, fallback: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : name
  }

  private static func userInfo(_ kind: ReminderKind, record: UUID, date: LocalDate) -> [String: String] {
    ["kind": kind.rawValue, "record": record.uuidString.lowercased(), "date": date.isoString]
  }
}
