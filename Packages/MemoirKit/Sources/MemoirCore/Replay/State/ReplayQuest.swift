import Foundation

/// A quest's schedule as its create and update commands left it; the owner's words are its `QuestRecord`. Deletion only deactivates, as the
/// reference's soft delete does, so its logs keep naming it.
public struct ReplayQuest: Sendable, Hashable {
  public let id: UUID
  public internal(set) var schedule: QuestSchedule
  /// Monotonic over creations; the most recently created quest wins a Returner tie, as the reference's serial id does.
  public let createdOrder: Int
  /// The account's day when it was created, which bounds the days the lock capacity counts.
  public let createdOn: LocalDate

  public var isActive: Bool { schedule.active }

  public func occurs(on date: LocalDate) -> Bool {
    schedule.recurrence.occurs(on: date)
  }

  /// `QST_003` is judged against the start time the quest has now, which the patch alone cannot see.
  mutating func apply(_ patch: QuestSchedulePatch) throws(ReplayRefusal) {
    let strictness = patch.strictness ?? schedule.strictness
    let startTime: Int? =
      switch patch.startTimeMinutes {
      case .keep: schedule.startTimeMinutes
      case .clear: nil
      case .set(let minute): minute
      }
    let moduleLink: QuestModuleLink? =
      switch patch.moduleLink {
      case .keep: schedule.moduleLink
      case .clear: nil
      case .set(let link): link
      }
    do throws(CommandRefusal) {
      schedule = try QuestSchedule(
        strictness: strictness, startTimeMinutes: startTime, durationMinutes: patch.durationMinutes ?? schedule.durationMinutes,
        statAffinity: patch.statAffinity ?? schedule.statAffinity, optionalStreakOptIn: patch.optionalStreakOptIn ?? schedule.optionalStreakOptIn,
        recurrence: patch.recurrence ?? schedule.recurrence, moduleLink: moduleLink, active: patch.active ?? schedule.active)
    } catch {
      throw .anchorNeedsStartTime
    }
  }

  mutating func deactivate() {
    guard
      let inactive = try? QuestSchedule(
        strictness: schedule.strictness, startTimeMinutes: schedule.startTimeMinutes, durationMinutes: schedule.durationMinutes, statAffinity: schedule.statAffinity,
        optionalStreakOptIn: schedule.optionalStreakOptIn, recurrence: schedule.recurrence, moduleLink: schedule.moduleLink, active: false)
    else { return }
    schedule = inactive
  }
}

public struct QuestStreak: Sendable, Hashable {
  public internal(set) var state: StreakState
  public internal(set) var runStartDate: LocalDate?
  public internal(set) var lastCountedDate: LocalDate?
}

/// One quest occurrence's outcome, with the snapshot of the quest the reference logs beside it, so a later schedule change never rewrites it.
public struct QuestLogEntry: Sendable, Hashable {
  /// The command or day close that first wrote the row; a yielding row's replacement keeps it, as the reference's upsert keeps the row id.
  public let id: UUID
  public internal(set) var state: QuestLogState
  public internal(set) var xpAwarded: Int
  public internal(set) var coinsAwarded: Int
  public internal(set) var statAffinity: StatAffinity
  public internal(set) var strictness: Strictness
  public internal(set) var intensityModeAtLog: IntensityMode
  public internal(set) var crownSliceWeight: Halves
  public internal(set) var rulesetVersion: Int
  public internal(set) var reasonTag: ReasonTag?
  /// The command whose `CommandNoteRecord` holds the reason note.
  public internal(set) var reasonNote: UUID?
  /// The command whose `CommandNoteRecord` holds the reflection.
  public internal(set) var reflection: UUID?
  public internal(set) var rescheduledToMinute: Int?
  public internal(set) var postponedToDate: LocalDate?
  public internal(set) var performedAtMillis: Int64?
  /// The recorded instant the row was first written; the edit window runs from it.
  public let createdAtMillis: Int64

  /// The states that never hold an occurrence against a user's action: a system miss and a bare reschedule marker (`YIELDING_STATES`).
  public static let yieldingStates: Set<QuestLogState> = [.missed, .rescheduled]
  public static let holdStates: Set<QuestLogState> = [.completed, .partial, .late, .recovery]
  public static let breakStates: Set<QuestLogState> = [.missed, .skipped, .postponed]

  public var isHold: Bool { Self.holdStates.contains(state) }
  public var isBreak: Bool { Self.breakStates.contains(state) }
}

/// A row as the reference's `QuestLogWrite` describes it.
struct QuestLogWrite: Sendable, Hashable {
  var id: UUID
  var state: QuestLogState
  var xpAwarded = 0
  var coinsAwarded = 0
  var statAffinity: StatAffinity
  var strictness: Strictness
  var intensityModeAtLog: IntensityMode
  var crownSliceWeight: Halves
  var rulesetVersion: Int
  var reasonTag: ReasonTag?
  var reasonNote: UUID?
  var rescheduledToMinute: Int?
  var postponedToDate: LocalDate?
  var performedAtMillis: Int64?
  var atMillis: Int64

  var entry: QuestLogEntry {
    QuestLogEntry(
      id: id, state: state, xpAwarded: xpAwarded, coinsAwarded: coinsAwarded, statAffinity: statAffinity, strictness: strictness, intensityModeAtLog: intensityModeAtLog,
      crownSliceWeight: crownSliceWeight, rulesetVersion: rulesetVersion, reasonTag: reasonTag, reasonNote: reasonNote, reflection: nil,
      rescheduledToMinute: rescheduledToMinute, postponedToDate: postponedToDate, performedAtMillis: performedAtMillis, createdAtMillis: atMillis)
  }
}

/// The reference's `reschedule_events` row: one per occurrence, kept even when the log it marked yields or is deleted.
public struct RescheduleEntry: Sendable, Hashable {
  public let fromMinute: Int?
  public let toMinute: Int
  public let reasonTag: ReasonTag?
  public let reasonNote: UUID?

  public var hasReason: Bool { reasonTag != nil || reasonNote != nil }
}
