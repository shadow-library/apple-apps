import Foundation

/// Where a day sits against the view's open day.
public enum DayRelation: String, Sendable, Hashable {
  case past
  case today
  case future
}

/// `features/quests/quest-presenters.ts:145-147`: a streak counts days only for a quest that runs every day.
public enum StreakUnit: String, Sendable, Hashable {
  case days
  case occurrences
}

/// `lib/data/fixture-provider.ts:361-364`.
public enum StreakStanding: Sendable, Hashable {
  case running(days: Int)
  case ended(longestDays: Int)
  case notStarted
}

/// A quest as a screen lists it: the owner's words from its `QuestRecord` (nil while the record is missing or unreadable) and its schedule from replay.
public struct QuestSnapshot: Sendable, Hashable, Identifiable {
  public let id: UUID
  public let name: String?
  public let notes: String?
  public let strictness: Strictness
  public let statAffinity: StatAffinity
  public let startMinute: Int?
  public let durationMinutes: Int
  public let recurrence: RecurrenceRule
  public let recurrenceSummary: RecurrenceSummary
  public let moduleLink: QuestModuleLink?
  public let optionalStreakOptIn: Bool
  public let isActive: Bool
  public let createdOn: LocalDate
  public let createdOrder: Int
}

public struct StreakSummary: Sendable, Hashable {
  public let currentDays: Int
  public let longestDays: Int
  public let shields: Int
  public let completionsTowardShield: Int
  public let pendingShieldGrant: Int
  /// Whether the quest keeps a streak at all: never for Recovery, only when opted in for Optional.
  public let isTracked: Bool
  public let unit: StreakUnit
  public let runStartDate: LocalDate?

  public var standing: StreakStanding {
    if currentDays > 0 { return .running(days: currentDays) }
    return longestDays > 0 ? .ended(longestDays: longestDays) : .notStarted
  }
}

/// An occurrence with nothing recorded is open on the view's day, upcoming after it and unrecorded before it (a day the walk never closed with it, such as
/// one beyond the catch-up limit); otherwise it holds its log's state.
public enum OccurrenceStatus: Sendable, Hashable {
  case open
  case upcoming
  case unrecorded
  case recorded(QuestLogState)
}

/// An occurrence's log. The words of a reason or reflection are the command's note record; only whether one exists is here.
public struct OccurrenceLog: Sendable, Hashable {
  public let id: UUID
  public let state: QuestLogState
  public let xpAwarded: Int
  public let coinsAwarded: Int
  public let reasonTag: ReasonTag?
  /// The command whose `CommandNoteRecord` holds the reason note.
  public let reasonNote: UUID?
  /// The command whose `CommandNoteRecord` holds the reflection.
  public let reflection: UUID?
  public let rescheduledToMinute: Int?
  public let postponedTo: LocalDate?
  public let performedAtMillis: Int64?
  public let createdAtMillis: Int64
  /// A reason or reflection can be attached until this instant (`quest-commands.service.ts:67`); deletion has no window.
  public let editableUntilMillis: Int64
  public let shielded: Bool
  public let intensityModeAtLog: IntensityMode

  init(_ row: QuestLogRow) {
    let entry = row.entry
    id = entry.id
    state = entry.state
    xpAwarded = entry.xpAwarded
    coinsAwarded = entry.coinsAwarded
    reasonTag = entry.reasonTag
    reasonNote = entry.reasonNote
    reflection = entry.reflection
    rescheduledToMinute = entry.rescheduledToMinute
    postponedTo = entry.postponedToDate
    performedAtMillis = entry.performedAtMillis
    createdAtMillis = entry.createdAtMillis
    editableUntilMillis = Int64(clamping: Int128(entry.createdAtMillis) + Int128(ReplayState.editWindowMillis))
    shielded = row.shielded
    intensityModeAtLog = entry.intensityModeAtLog
  }

  /// A log still waiting for its outcome: the system's miss and a bare reschedule both yield to the owner's action (`YIELDING_STATES`).
  public var isYielding: Bool { QuestLogEntry.yieldingStates.contains(state) }
}

/// The reschedule cap of one occurrence: reschedules of the quest dated in the seven days ending on it (`quest-commands.service.ts:65-66`).
public struct RescheduleBudget: Sendable, Hashable {
  public static let cap = ReplayState.rescheduleCapPerWindow
  public static let windowDays = ReplayState.rescheduleWindowDays

  public let used: Int
  public let cap: Int
  /// Reschedules of the quest already booked for later days.
  public let bookedAhead: Int
  /// The first later occurrence date the cap no longer binds; nil while it does not bind.
  public let freesOn: LocalDate?

  public var isCapReached: Bool { used >= cap }

  /// `rescheduledDates` are the quest's reschedules, in any order.
  static func of(_ rescheduledDates: [LocalDate], on date: LocalDate) -> RescheduleBudget {
    let used = count(rescheduledDates, endingOn: date)
    let ahead = rescheduledDates.count { $0 > date }
    guard used >= cap else { return RescheduleBudget(used: used, cap: cap, bookedAhead: ahead, freesOn: nil) }
    let latest = rescheduledDates.max() ?? date
    let horizon = max(latest.days(since: date), 0) + windowDays
    let freesOn = (1...horizon).lazy.map { date.movedBy(days: $0) }.first { count(rescheduledDates, endingOn: $0) < cap }
    return RescheduleBudget(used: used, cap: cap, bookedAhead: ahead, freesOn: freesOn)
  }

  private static func count(_ dates: [LocalDate], endingOn date: LocalDate) -> Int {
    let start = date.movedBy(days: -(windowDays - 1))
    return dates.count { $0 >= start && $0 <= date }
  }
}

/// What a break (a skip or a postpone, or the miss of an open occurrence) would cost: the HP the day's close charges (`rules/hp.ts`, with the
/// `streakDaysBefore: 0` the rollover passes) and what happens to the streak (`rules/streak.ts`). `quest-presenters.ts:186-205`.
public struct BreakCost: Sendable, Hashable {
  public let hp: Int
  public let streak: StreakBreak
}

public enum StreakBreak: Sendable, Hashable {
  case untracked
  case bridgedByShield(shieldsLeft: Int)
  case ends(atDays: Int)
}

public enum ActionAvailability: Sendable, Hashable {
  case available
  /// Available until the instant, inclusive, as replay judges the command's recorded instant (the log's edit window).
  case availableUntil(millis: Int64)
  case needsConfirmation(ActionConfirmation)
  case unavailable(ActionBlock)

  /// Whether a command issued at the instant would be taken; a confirmation still has to be asked for.
  public func isPossible(at instantMillis: Int64) -> Bool {
    switch self {
    case .available, .needsConfirmation: true
    case .availableUntil(let millis): instantMillis <= millis
    case .unavailable: false
    }
  }
}

public enum ActionConfirmation: Sendable, Hashable {
  /// Past the cap a reschedule the owner accepts is recorded as a postpone (`quest-commands.service.ts`, `acceptBeyondCap`).
  case rescheduleBecomesPostpone(RescheduleBudget)
  /// A postpone of a quest in today's active lock breaks the lock, and its bonus stops for every quest in it.
  case breaksPlanLock
}

/// Why replay would refuse, supersede or reject the action, or why it has no meaning for the occurrence.
public enum ActionBlock: Sendable, Hashable {
  case questInactive
  case notScheduled
  case notYetBegun
  /// The day has closed; only the log's edits still apply (`quest-presenters.ts:73`, `quest-actions.tsx:259,266`).
  case dayPassed
  case notAccountDay
  case alreadyRecorded(QuestLogState)
  case alreadyRescheduled
  case notAllowedFor(Strictness)
  case rescheduleCapReached(RescheduleBudget)
  case nothingRecorded
  case nothingToLock
  case notLocked
  case recoveryClosed(RecoveryQuestState)
  /// The quest is in today's active lock, so its schedule stays as planned (`quest-builder-screen.tsx:259-266`).
  case lockedInTodaysPlan
  /// The day's money logging is already covered, by an expense dated that day or an earlier "No spend".
  case alreadyCovered(MoneyLogSource)
  /// The day is past the money rules' late window, so logging no longer covers it.
  case loggingWindowClosed
}

public struct OccurrenceActions: Sendable, Hashable {
  public let complete: ActionAvailability
  public let partial: ActionAvailability
  public let skip: ActionAvailability
  public let postpone: ActionAvailability
  public let reschedule: ActionAvailability
  public let attachReason: ActionAvailability
  public let deleteLog: ActionAvailability
}

/// One quest's occurrence on one day, with everything a row on Today, the Plan or a quest's page shows and may do.
public struct BoardOccurrence: Sendable, Hashable, Identifiable {
  public let occurrence: Occurrence
  public let quest: QuestSnapshot
  public let streak: StreakSummary
  /// False for a logged occurrence of a quest that no longer runs that day, or was deleted.
  public let isScheduled: Bool
  public let status: OccurrenceStatus
  public let log: OccurrenceLog?
  /// `fixture-provider.ts:519-521`: an occurrence still open, or only moved, once its day has passed reads as missed on a board.
  public let effectiveState: QuestLogState?
  public let locked: Bool
  public let intensityMode: IntensityMode
  /// The minute a completion turns late (`rules/timing.ts`): the start plus the grace for a strict-time quest, plus the duration for a time window.
  public let onTimeUntilMinute: Int?
  public let breakCost: BreakCost
  public let reschedule: RescheduleBudget
  public let actions: OccurrenceActions

  public var id: Occurrence { occurrence }

  /// The minute the occurrence is planned for today: where a reschedule moved it, else the quest's start.
  public var plannedMinute: Int? {
    if case .recorded(.rescheduled) = status, let minute = log?.rescheduledToMinute { return minute }
    return quest.startMinute
  }
}

/// `lib/data/quest.rules.ts:7`: completed, late and recovery count as kept; a partial is reported on its own.
public struct DayTally: Sendable, Hashable {
  public static let keptStates: Set<QuestLogState> = [.completed, .late, .recovery]

  public let scheduled: Int
  public let kept: Int
  public let partial: Int
  public let skipped: Int
  public let postponed: Int
  public let missed: Int
  public let open: Int

  init(_ occurrences: [BoardOccurrence]) {
    let scheduled = occurrences.filter(\.isScheduled)
    self.scheduled = scheduled.count
    kept = scheduled.count { $0.effectiveState.map(Self.keptStates.contains) == true }
    partial = scheduled.count { $0.effectiveState == .partial }
    skipped = scheduled.count { $0.effectiveState == .skipped }
    postponed = scheduled.count { $0.effectiveState == .postponed }
    missed = scheduled.count { $0.effectiveState == .missed }
    open = scheduled.count { $0.effectiveState == nil || $0.effectiveState == .rescheduled }
  }
}

extension LocalDate {
  /// `adding(days:)` held to the supported calendar.
  func movedBy(days: Int) -> LocalDate {
    adding(days: days) ?? (days < 0 ? .earliest : .latest)
  }
}
