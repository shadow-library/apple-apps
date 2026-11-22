import Foundation
import ShadowStore

/// A quest being created or edited, before any command: the builder's values, loosely held so a preview can still say what is wrong with them.
public struct QuestDraft: Sendable, Hashable {
  public var name: String
  public var strictness: Strictness
  public var startTimeMinutes: Int?
  public var durationMinutes: Int
  public var recurrence: RecurrenceRule
  public var isActive: Bool
  /// The quest being edited, whose own occurrences the preview replaces rather than adds to.
  public var editing: UUID?

  public init(
    name: String, strictness: Strictness, startTimeMinutes: Int? = nil, durationMinutes: Int = 0, recurrence: RecurrenceRule, isActive: Bool = true,
    editing: UUID? = nil
  ) {
    self.name = name
    self.strictness = strictness
    self.startTimeMinutes = startTimeMinutes
    self.durationMinutes = durationMinutes
    self.recurrence = recurrence
    self.isActive = isActive
    self.editing = editing
  }
}

/// `blockedReason` (`features/quests/quest-builder-screen.tsx:159-166`) and `QST_003`.
public enum DraftIssue: Sendable, Hashable {
  case nameRequired
  case intervalOutOfRange(Int)
  case anchorNeedsStartTime
  case startMinuteOutOfRange(Int)
  case durationOutOfRange(Int)
}

public struct DraftPreviewQuery: Sendable, Hashable {
  public let draft: QuestDraft

  public init(draft: QuestDraft) {
    self.draft = draft
  }
}

/// One day of the week the draft would join: its planned minutes with the draft, and whether the draft runs that day.
public struct DraftPreviewDay: Sendable, Hashable, Identifiable {
  public let date: LocalDate
  /// Days after the open day: 0 today, 1 tomorrow.
  public let offset: Int
  public let minutes: Int
  public let draftRuns: Bool

  public var isOverCapacity: Bool { minutes > DayLoad.softCapacityMinutes }
  public var id: LocalDate { date }
}

/// "Effect on your week" (`fixture-provider.ts:608-631`): the seven days from the later of today and the draft's start, each day's minutes with the draft
/// in place, how often it runs, and the heaviest day when it goes over the soft capacity. Computed from the projection; nothing is written.
public struct DraftPreview: ReplayReadModel {
  public static let windowDays = 7
  public static let intervalRange = 1...30
  public static let durationRange = 0...240

  public let issues: [DraftIssue]
  public let days: [DraftPreviewDay]
  /// Occurrences in the window, for an every-`n`-days draft (`fixture-provider.ts:131-134`); nil for another frequency.
  public let dailyCadence: Int?
  /// Set only when the heaviest day is over the soft capacity: a note, not a limit.
  public let overload: DraftPreviewDay?
  /// An edited quest in today's active lock keeps its schedule; only its words may change (`quest-builder-screen.tsx:259-266`).
  public let scheduleEdit: ActionAvailability
  public let changesOn: LocalDate?

  public var isValid: Bool { issues.isEmpty }

  public static func load(_ query: DraftPreviewQuery, in transaction: ReadTransaction) throws(StoreError) -> DraftPreview {
    let context = try QuestReadContext.load(in: transaction)
    let draft = query.draft
    let today = context.openDay ?? draft.recurrence.startDate
    let start = max(today, draft.recurrence.startDate)
    let end = start.movedBy(days: windowDays - 1)
    let source = try OccurrenceSource.load(context, from: start, through: end, in: transaction)
    let runs = draft.isActive ? Set(draft.recurrence.expand(from: start, through: end).occurrences.map(\.date)) : []
    let days = (0..<windowDays).map { start.movedBy(days: $0) }.map { date in
      let others = context.activeQuests.filter { $0.id != draft.editing && source.isScheduled($0, on: date) }
      let minutes = Exact.sum(others.map { max(0, $0.schedule.durationMinutes) }) + (runs.contains(date) ? clamped(draft.durationMinutes) : 0)
      return DraftPreviewDay(date: date, offset: date.days(since: today), minutes: minutes, draftRuns: runs.contains(date))
    }
    let heaviest = days.reduce(days[0]) { worst, day in day.minutes > worst.minutes ? day : worst }
    let isDaily = if case .daily = draft.recurrence.frequency { true } else { false }
    return DraftPreview(
      issues: issues(of: draft, context: context), days: days, dailyCadence: isDaily ? runs.count : nil, overload: heaviest.isOverCapacity ? heaviest : nil,
      scheduleEdit: draft.editing.map(context.isLockedToday) == true ? .unavailable(.lockedInTodaysPlan) : .available, changesOn: context.changesOn)
  }

  /// The week effect clamps the length into range, as the builder shows it while the field is still being typed (`quest-builder-screen.tsx:487`).
  private static func clamped(_ minutes: Int) -> Int {
    min(durationRange.upperBound, max(durationRange.lowerBound, minutes))
  }

  private static func issues(of draft: QuestDraft, context: QuestReadContext) -> [DraftIssue] {
    var issues = [DraftIssue]()
    if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.nameRequired) }
    if case .daily = draft.recurrence.frequency, !intervalRange.contains(draft.recurrence.interval) {
      issues.append(.intervalOutOfRange(draft.recurrence.interval))
    }
    if let minute = draft.startTimeMinutes, !(0..<1440).contains(minute) { issues.append(.startMinuteOutOfRange(minute)) }
    if draft.strictness == .anchor && draft.startTimeMinutes == nil { issues.append(.anchorNeedsStartTime) }
    if !durationRange.contains(draft.durationMinutes) { issues.append(.durationOutOfRange(draft.durationMinutes)) }
    return issues
  }
}
