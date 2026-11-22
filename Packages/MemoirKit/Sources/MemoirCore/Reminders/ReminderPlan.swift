import Foundation
import ShadowCore

public enum ReminderQueryError: ShadowError, Equatable {
  case horizonOutOfRange(Int)
  case negativeLimit(Int)

  public var code: String {
    switch self {
    case .horizonOutOfRange: "memoir_reminder.horizon_out_of_range"
    case .negativeLimit: "memoir_reminder.negative_limit"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .horizonOutOfRange(let days): "A reminder window spans 1 to \(ReminderQuery.maximumHorizonDays) days, not \(days)."
    case .negativeLimit(let limit): "A reminder plan holds zero or more reminders, not \(limit)."
    }
  }
}

/// The window a plan covers, from `now` for `horizonDays` days, and how many reminders it keeps, the soonest first. `device` governs only before the
/// account has a zone, so the app restarts an observation when the device's zone changes.
public struct ReminderQuery: Sendable, Hashable {
  public static let defaultHorizonDays = 7
  public static let maximumHorizonDays = 31
  /// iOS keeps at most 64 pending local notification requests per app and drops the rest.
  public static let systemPendingLimit = 64

  public let horizonDays: Int
  public let limit: Int
  public let device: TimeZone

  public init(horizonDays: Int = defaultHorizonDays, limit: Int, device: TimeZone) throws(ReminderQueryError) {
    guard (1...Self.maximumHorizonDays).contains(horizonDays) else { throw .horizonOutOfRange(horizonDays) }
    guard limit >= 0 else { throw .negativeLimit(limit) }
    self.horizonDays = horizonDays
    self.limit = limit
    self.device = device
  }
}

/// What the app changes in its pending notification requests: requests to add, in fire order, and identifiers to remove. Only identifiers under
/// `Reminder.identifierPrefix` are ever removed, so the app's other requests are left alone.
public struct ReminderDiff: Sendable, Equatable {
  public let add: [Reminder]
  public let remove: [String]

  public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
}

/// The reminders that fire after `now` and within the query's window, soonest first and at most `limit` of them. Built from the projection, never by
/// running replay: an occurrence with any log but a reschedule (completed, late, partial, skipped, postponed, missed, recovery) is not reminded, and a
/// rescheduled one is reminded at its new minute. A timed occurrence fires its lead before its start; one without a time of day, and a subscription's
/// reminder day, fire at the start of the owner's wake window. Local times resolve in the zone in force on their day (the staged zone after the open
/// day) by `IssueClock.resolve(minuteOfDay:on:)`: a time inside a spring-forward gap moves to the transition, and a repeated one takes the earlier instant.
/// After a replay halt no quest is reminded, since the projection no longer sees completions or deletions synced from other devices.
public struct ReminderPlan: Sendable, Equatable {
  public let reminders: [Reminder]
  /// Reminders inside the window left out by the limit.
  public let omitted: Int
  /// When the plan next changes with no write: the soonest reminder's fire instant, the instant the next reminder beyond the window enters it, or the next
  /// midnight in the zone in force, whichever comes first.
  public let changesAt: Date
  /// Set when replay stopped at a command this build cannot read; quest occurrences then reflect the projection only up to it.
  public let halt: ReplayHalt?

  public static func make(_ sources: ReminderSources, query: ReminderQuery, now: Date) -> ReminderPlan {
    let nowMillis = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
    let end = nowMillis + Int64(query.horizonDays) * millisPerDay
    let resolver = LocalTimes(zone: sources.zone, device: query.device, nowMillis: nowMillis)
    let quests = sources.halt == nil ? questReminders(sources, resolver: resolver, through: end) : []
    let candidates = quests + subscriptionReminders(sources, resolver: resolver)
    let inWindow = candidates.filter { $0.fireAtMillis > nowMillis && $0.fireAtMillis <= end }.sorted { ($0.fireAtMillis, $0.identifier) < ($1.fireAtMillis, $1.identifier) }
    let kept = Array(inWindow.prefix(query.limit))
    let entering = candidates.filter { $0.fireAtMillis > end }.map(\.fireAtMillis).min().map { $0 - (end - nowMillis) }
    let changes = [kept.first?.fireAtMillis, entering, resolver.nextMidnight()].compactMap(\.self).min() ?? end
    return ReminderPlan(
      reminders: kept, omitted: inWindow.count - kept.count, changesAt: Date(timeIntervalSince1970: TimeInterval(changes) / 1000), halt: sources.halt)
  }

  public var identifiers: Set<String> { Set(reminders.map(\.identifier)) }

  /// `pending` is every identifier the app has pending, its own other requests included.
  public func diff(against pending: Set<String>) -> ReminderDiff {
    let planned = identifiers
    return ReminderDiff(
      add: reminders.filter { !pending.contains($0.identifier) },
      remove: pending.filter { $0.hasPrefix(Reminder.identifierPrefix) && !planned.contains($0) }.sorted())
  }

  private static let millisPerMinute: Int64 = 60_000
  private static let millisPerDay: Int64 = 86_400_000

  private static func questReminders(_ sources: ReminderSources, resolver: LocalTimes, through end: Int64) -> [Reminder] {
    guard let longestLead = sources.quests.map(\.leadMinutes).max(), let first = resolver.today?.adding(days: -1),
      let last = resolver.date(at: end + Int64(longestLead) * millisPerMinute)?.adding(days: 1)
    else { return [] }
    var reminders = [Reminder]()
    for quest in sources.quests {
      for occurrence in quest.schedule.recurrence.expand(from: first, through: last).occurrences {
        let date = occurrence.date
        let logged = sources.logs[Occurrence(quest: quest.id, date: date)]
        if let logged, logged.state != .rescheduled { continue }
        let minute = logged?.rescheduledToMinute ?? quest.schedule.startTimeMinutes
        let content = QuestReminder(
          quest: quest.id, name: quest.name, date: date, startMinute: minute, leadMinutes: minute == nil ? 0 : quest.leadMinutes, isRescheduled: logged != nil)
        guard let start = resolver.instant(minute: minute ?? sources.wakeWindow.start, on: date) else { continue }
        reminders.append(Reminder(fireAtMillis: start - Int64(content.leadMinutes) * millisPerMinute, content: .quest(content)))
      }
    }
    return reminders
  }

  private static func subscriptionReminders(_ sources: ReminderSources, resolver: LocalTimes) -> [Reminder] {
    sources.subscriptions.compactMap { subscription in
      guard let day = subscription.nextDue.adding(days: -subscription.lead.days), let fire = resolver.instant(minute: sources.wakeWindow.start, on: day) else {
        return nil
      }
      let content = SubscriptionReminder(
        subscription: subscription.id, name: subscription.name, dueOn: subscription.nextDue, amount: subscription.amount, lead: subscription.lead)
      return Reminder(fireAtMillis: fire, content: .subscription(content))
    }
  }
}

/// Local minutes of the account's days as instants, each in the clock `AccountZone` puts in force on that day.
private struct LocalTimes {
  let zone: AccountZone
  let device: TimeZone
  let nowMillis: Int64
  let clock: IssueClock
  /// Noon of a day in the offset a staged change was issued under lies on that day as `AccountZone.resolve(at:device:)` measures it.
  private let probeOffsetMillis: Int64

  init(zone: AccountZone, device: TimeZone, nowMillis: Int64) {
    self.zone = zone
    self.device = device
    self.nowMillis = nowMillis
    clock = zone.clock(at: nowMillis, device: device)
    probeOffsetMillis = Int64(zone.staged?.issuedUnderOffsetMinutes ?? 0) * 60_000
  }

  var today: LocalDate? { try? clock.localDate(at: nowMillis) }

  func date(at instantMillis: Int64) -> LocalDate? {
    try? zone.clock(at: instantMillis, device: device).localDate(at: instantMillis)
  }

  func instant(minute: Int, on date: LocalDate) -> Int64? {
    let noon = Int64(date.daysSinceEpoch) * 86_400_000 + 43_200_000 - probeOffsetMillis
    return try? zone.clock(at: noon, device: device).resolve(minuteOfDay: minute, on: date).instantMillis
  }

  func nextMidnight() -> Int64? {
    guard let tomorrow = today?.adding(days: 1) else { return nil }
    return try? clock.startOfDay(tomorrow)
  }
}
