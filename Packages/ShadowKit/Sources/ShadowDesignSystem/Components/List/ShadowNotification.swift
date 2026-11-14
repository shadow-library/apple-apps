import Foundation

nonisolated public enum ShadowDayBucket: Hashable, Sendable, CaseIterable {
  case today
  case yesterday
  case earlier

  public init(date: Date, now: Date, calendar: Calendar = .current) {
    if date >= now || calendar.isDate(date, inSameDayAs: now) {
      self = .today
    } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      self = .yesterday
    } else {
      self = .earlier
    }
  }
}

nonisolated public struct ShadowNotificationGroup<ID: Hashable & Sendable>: Identifiable, Sendable {
  public let bucket: ShadowDayBucket
  public let notifications: [ShadowNotification<ID>]

  public var id: ShadowDayBucket { bucket }
}

nonisolated public enum ShadowNotificationIcon: Hashable, Sendable {
  case none
  case symbol(String, tint: ShadowAvatarTint = .accent)
  case avatar(name: String)
}

nonisolated public struct ShadowNotification<ID: Hashable & Sendable>: Identifiable, Hashable, Sendable {
  public let id: ID
  public var title: String
  public var message: String?
  public var source: String?
  public var date: Date
  public var isRead: Bool
  public var icon: ShadowNotificationIcon

  public init(id: ID, title: String, message: String? = nil, source: String? = nil, date: Date, isRead: Bool = false, icon: ShadowNotificationIcon = .none) {
    self.id = id
    self.title = title
    self.message = message
    self.source = source
    self.date = date
    self.isRead = isRead
    self.icon = icon
  }
}

nonisolated extension Collection {
  public func shadowUnreadCount<ID: Hashable & Sendable>() -> Int where Element == ShadowNotification<ID> {
    count { !$0.isRead }
  }

  public func shadowGroupedByDay<ID: Hashable & Sendable>(now: Date, calendar: Calendar = .current) -> [ShadowNotificationGroup<ID>] where Element == ShadowNotification<ID> {
    let sorted = self.sorted { $0.date > $1.date }
    return ShadowDayBucket.allCases.compactMap { bucket in
      let members = sorted.filter { ShadowDayBucket(date: $0.date, now: now, calendar: calendar) == bucket }
      return members.isEmpty ? nil : ShadowNotificationGroup(bucket: bucket, notifications: members)
    }
  }
}

nonisolated public enum ShadowRelativeTime {
  public static func string(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
    switch ShadowDayBucket(date: date, now: now, calendar: calendar) {
    case .today:
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .abbreviated
      formatter.dateTimeStyle = .named
      formatter.calendar = calendar
      formatter.locale = locale
      return formatter.localizedString(for: min(date, now), relativeTo: now)
    case .yesterday:
      return format(date, .dateTime.weekday(.abbreviated), calendar: calendar, locale: locale)
    case .earlier:
      let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
      if days < 7 { return format(date, .dateTime.weekday(.abbreviated), calendar: calendar, locale: locale) }
      let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
      return format(date, sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year(), calendar: calendar, locale: locale)
    }
  }

  private static func format(_ date: Date, _ style: Date.FormatStyle, calendar: Calendar, locale: Locale) -> String {
    var style = style
    style.calendar = calendar
    style.locale = locale
    style.timeZone = calendar.timeZone
    return date.formatted(style)
  }
}
