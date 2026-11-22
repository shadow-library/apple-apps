import Foundation
import ShadowCore

public enum ReminderKind: String, Sendable, Hashable, CaseIterable {
  case quest
  case subscription
}

/// An occurrence of a quest the owner asked to be reminded of. `startMinute` is where the occurrence is planned (a reschedule's minute, else the quest's
/// start), nil for a quest without a time of day, which is reminded at the start of the wake window with no lead.
public struct QuestReminder: Sendable, Hashable {
  public let quest: UUID
  public let name: String
  public let date: LocalDate
  public let startMinute: Int?
  public let leadMinutes: Int
  public let isRescheduled: Bool
}

/// A subscription's open cycle, reminded at the start of the wake window on the day its lead names.
public struct SubscriptionReminder: Sendable, Hashable {
  public let subscription: UUID
  public let name: String
  public let dueOn: LocalDate
  public let amount: MoneyAmount
  public let lead: SubscriptionReminderLead
}

/// What a reminder is about, as data only: the app writes the words.
public enum ReminderContent: Sendable, Hashable {
  case quest(QuestReminder)
  case subscription(SubscriptionReminder)

  public var kind: ReminderKind {
    switch self {
    case .quest: .quest
    case .subscription: .subscription
    }
  }

  var record: UUID {
    switch self {
    case .quest(let reminder): reminder.quest
    case .subscription(let reminder): reminder.subscription
    }
  }

  var occurrenceDate: LocalDate {
    switch self {
    case .quest(let reminder): reminder.date
    case .subscription(let reminder): reminder.dueOn
    }
  }

  fileprivate var fingerprint: [String] {
    switch self {
    case .quest(let reminder):
      [reminder.name, reminder.startMinute.map(String.init) ?? "-", String(reminder.leadMinutes), reminder.isRescheduled ? "rescheduled" : "planned"]
    case .subscription(let reminder):
      [reminder.name, String(reminder.amount.amountMinor), reminder.amount.currency.code, reminder.lead.rawValue]
    }
  }
}

/// What a reminder is about: the kind, the quest or subscription, and the occurrence's date (a subscription cycle's due date). The app keeps it beside
/// each request, and `ReminderPlan.settled` names it.
public struct ReminderOccurrence: Sendable, Hashable {
  public let kind: ReminderKind
  public let record: UUID
  public let date: LocalDate

  public init(kind: ReminderKind, record: UUID, date: LocalDate) {
    self.kind = kind
    self.record = record
    self.date = date
  }

  public var id: UUID { Reminder.occurrenceID(kind: kind, record: record, date: date) }
}

/// One local notification to schedule. `occurrenceID` names the occurrence alone (kind, record, date); `identifier` also binds the fire instant and the
/// content, so an edited lead, time, name or amount yields a new identifier and `ReminderPlan.diff(against:)` replaces the pending request.
public struct Reminder: Sendable, Hashable, Identifiable {
  public static let identifierPrefix = "com.shadow.library.memoircore.reminder."
  public static let occurrenceDomain = "com.shadow.library.memoircore.reminder-occurrence"
  public static let requestDomain = "com.shadow.library.memoircore.reminder-request"

  public let identifier: String
  public let occurrenceID: UUID
  public let fireAtMillis: Int64
  public let content: ReminderContent

  init(fireAtMillis: Int64, content: ReminderContent) {
    let occurrenceID = Self.occurrenceID(kind: content.kind, record: content.record, date: content.occurrenceDate)
    let parts = [occurrenceID.lowercasedString, String(fireAtMillis)] + content.fingerprint
    identifier = Self.identifierPrefix + derivedID(Self.requestDomain, parts.map { "\($0.utf8.count):\($0)" }.joined()).lowercasedString
    self.occurrenceID = occurrenceID
    self.fireAtMillis = fireAtMillis
    self.content = content
  }

  public static func occurrenceID(kind: ReminderKind, record: UUID, date: LocalDate) -> UUID {
    derivedID(occurrenceDomain, "\(kind.rawValue)|\(record.lowercasedString)|\(date.isoString)")
  }

  public var id: String { identifier }

  public var occurrence: ReminderOccurrence { ReminderOccurrence(kind: content.kind, record: content.record, date: content.occurrenceDate) }

  public var fireAt: Date { Date(timeIntervalSince1970: TimeInterval(fireAtMillis) / 1000) }
}
