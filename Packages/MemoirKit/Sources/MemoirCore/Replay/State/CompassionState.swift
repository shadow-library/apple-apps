import Foundation

public enum RecoveryQuestState: String, RuleKey, Codable {
  case pending
  case completed
  case expired
}

/// A day's Recovery quest, spawned by the day walk after an anchor or routine miss and completed by `recovery.complete`.
public struct RecoveryQuest: Sendable, Hashable, Codable {
  public let id: UUID
  public let date: LocalDate
  public let sourceQuest: UUID?
  public let triggerLogs: [UUID]
  public let isReturnerDay: Bool
  public internal(set) var state: RecoveryQuestState
  /// The command whose `CommandNoteRecord` holds the reflection.
  public internal(set) var reflection: UUID?
  public internal(set) var completedAtMillis: Int64?
  /// The start of the next day at the offset the walk recorded when it spawned the quest, as the reference stores `expires_at`; the day's close expires it.
  public internal(set) var expiresAtMillis: Int64?
}

/// The reference's `returner_events` row.
public struct ReturnerEvent: Sendable, Hashable, Codable {
  public let date: LocalDate
  public let lastActiveDate: LocalDate
  public let daysAbsent: Int
  public let shieldTarget: UUID?
  public let shieldPending: Bool
  public let intensityMode: IntensityMode
}

/// The compassion mechanics that outlive one day; each day's Comeback and plan lock live on its `ReplayDay`, and the intensity mode in `ReplaySettings`.
public struct CompassionState: Sendable, Hashable, Codable {
  public static let empty = CompassionState()

  public internal(set) var recoveries: [LocalDate: RecoveryQuest] = [:]
  public internal(set) var returnerEvents: [LocalDate: ReturnerEvent] = [:]
  /// A Returner shield with no quest to aim at waits here for the next quest created.
  public internal(set) var pendingReturnerShields = 0
  /// The latest closed day with a hold-state log, which the Returner measures the absence from.
  public internal(set) var lastActiveDate: LocalDate?
}
