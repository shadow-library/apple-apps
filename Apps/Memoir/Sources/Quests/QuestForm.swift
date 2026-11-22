import Foundation
import MemoirCore

nonisolated enum QuestRepeat: String, Hashable, Sendable, CaseIterable {
  case weekly
  case everyNDays
}

/// Why the builder will not save yet, in the order the reference names the first of them (`quest-builder-screen.tsx:159-166`): the draft's own issues as
/// `DraftPreview` reports them, the one a recurrence cannot even hold (a weekly quest with no day), and an edit that changes nothing.
nonisolated enum QuestFormIssue: Hashable, Sendable {
  case draft(DraftIssue)
  case noWeekdays
  case unchanged

  var rank: Int {
    switch self {
    case .draft(.nameRequired): 0
    case .noWeekdays: 1
    case .draft(.intervalOutOfRange): 2
    case .draft(.anchorNeedsStartTime): 3
    case .draft(.startMinuteOutOfRange): 4
    case .draft(.durationOutOfRange): 5
    case .unchanged: 6
    }
  }
}

/// The builder's values (`QuestFormValues`, `quest-builder-screen.tsx:47-57`) plus the record's reminder; loosely held so the form can say what is wrong.
nonisolated struct QuestForm: Hashable, Sendable {
  static let builderStrictness: [Strictness] = [.anchor, .routine, .goal, .optional]
  static let statOrder: [StatAffinity] = [.body, .mind, .wealth, .discipline]
  static let standardWeekdays: Set<LocalDate.Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
  static let standardInterval = 2
  static let standardDuration = 25
  static let durationStep = 5
  static let nameLimit = 120
  static let reminderLeads = [0, 5, 10, 15, 30, 60]
  static let standardReminderLead = 10

  var name = ""
  var statAffinity = StatAffinity.mind
  var strictness = Strictness.routine
  var startMinute: Int?
  var durationMinutes = standardDuration
  var repeats = QuestRepeat.weekly
  var interval = standardInterval
  var weekdays = standardWeekdays
  var threshold = false
  var reminderEnabled = false
  var reminderLeadMinutes = standardReminderLead

  init() {}

  /// `questValues` (`quest-builder-screen.tsx:74-87`).
  init(quest: QuestSnapshot, record: QuestRecord?, threshold: QuestThresholdSummary?) {
    name = record?.name ?? quest.name ?? ""
    statAffinity = quest.statAffinity
    strictness = quest.strictness
    startMinute = quest.startMinute
    durationMinutes = quest.durationMinutes
    switch quest.recurrence.frequency {
    case .daily:
      repeats = .everyNDays
      interval = quest.recurrence.interval
    case .weekly(let days):
      weekdays = days
    case .monthly, .yearly:
      break
    }
    self.threshold = threshold != nil
    reminderEnabled = record?.reminderEnabled ?? false
    reminderLeadMinutes = record?.reminderLeadMinutes ?? Self.standardReminderLead
  }

  /// "Duplicate as a new quest" (`quest-detail-screen.tsx:174-190`, `quest-duplicate.search.ts`): a field outside what the builder writes falls back to the
  /// new quest's default, and only the builder's own threshold is carried over.
  static func duplicating(_ quest: QuestSnapshot, record: QuestRecord?, threshold: QuestThresholdSummary?) -> QuestForm {
    var form = QuestForm()
    let name = record?.name ?? quest.name ?? ""
    if name.count <= nameLimit { form.name = name }
    form.statAffinity = quest.statAffinity
    if builderStrictness.contains(quest.strictness) { form.strictness = quest.strictness }
    form.startMinute = quest.startMinute
    if DraftPreview.durationRange.contains(quest.durationMinutes) { form.durationMinutes = quest.durationMinutes }
    switch quest.recurrence.frequency {
    case .daily:
      form.repeats = .everyNDays
      if DraftPreview.intervalRange.contains(quest.recurrence.interval) { form.interval = quest.recurrence.interval }
    case .weekly(let days):
      form.weekdays = days
    case .monthly, .yearly:
      break
    }
    form.threshold = threshold?.isStandard == true
    form.reminderEnabled = record?.reminderEnabled ?? false
    form.reminderLeadMinutes = record?.reminderLeadMinutes ?? standardReminderLead
    return form
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Adding a time turns the reminder on and clearing it turns it off, as the reference's notification follows the start time
  /// (`quest-builder-screen.tsx:120,137-138`); changing a time keeps the owner's choice.
  mutating func setStartMinute(_ minute: Int?) {
    if (minute == nil) != (startMinute == nil) { reminderEnabled = minute != nil }
    startMinute = minute
  }

  /// A reminder is a lead before the start, so an untimed quest keeps none.
  var savedReminderEnabled: Bool { reminderEnabled && startMinute != nil }

  var reminder: (enabled: Bool, lead: Int) { (savedReminderEnabled, reminderLeadMinutes) }

  /// `recurrenceFrom` (`quest-builder-screen.tsx:93-96`): an edit keeps the quest's start, end and exceptions, and a weekly one its week interval. Nil for a
  /// weekly quest with no day, which no recurrence can hold.
  func recurrence(base: RecurrenceRule?, today: LocalDate) -> RecurrenceRule? {
    let start = base?.startDate ?? today
    let end = base?.end ?? .never
    let exceptions = base?.exceptions ?? []
    switch repeats {
    case .everyNDays:
      return try? RecurrenceRule(frequency: .daily, interval: interval, startDate: start, end: end, exceptions: exceptions)
    case .weekly:
      let weekInterval = if case .weekly = base?.frequency { base?.interval ?? 1 } else { 1 }
      return try? RecurrenceRule(frequency: .weekly(weekdays), interval: weekInterval, startDate: start, end: end, exceptions: exceptions)
    }
  }

  /// `lockedValues` (`quest-builder-screen.tsx:150-153`): while the schedule is locked its fields keep the quest's values.
  func lockingSchedule(to original: QuestForm) -> QuestForm {
    var form = self
    form.strictness = original.strictness
    form.startMinute = original.startMinute
    form.repeats = original.repeats
    form.interval = original.interval
    form.weekdays = original.weekdays
    return form
  }
}

/// What saving an edit writes: the record's words and reminder when they moved, and the schedule patch (`questPatch`, `quest-builder-screen.tsx:105-127`).
nonisolated struct QuestEdit: Sendable, Equatable {
  let record: QuestRecord?
  let patch: QuestSchedulePatch?
  let threshold: ThresholdChange

  enum ThresholdChange: Sendable, Equatable {
    case keep
    case set
    case clear
  }

  var isEmpty: Bool { record == nil && patch == nil && threshold == .keep }

  /// `recurrence` is the form's recurrence, or nil when the schedule cannot change here.
  init(
    quest: QuestSnapshot, record current: QuestRecord?, hadThreshold: Bool, form: QuestForm, scheduleLocked: Bool, recurrence: RecurrenceRule?
  ) throws(CommandRefusal) {
    let name = form.trimmedName
    let reminder = form.reminder
    if current?.name != name || current?.reminderEnabled != reminder.enabled || current?.reminderLeadMinutes != reminder.lead {
      var record = current ?? QuestRecord(id: quest.id, name: name)
      record.name = name
      record.reminderEnabled = reminder.enabled
      record.reminderLeadMinutes = reminder.lead
      self.record = record
    } else {
      self.record = nil
    }
    threshold = form.threshold == hadThreshold ? .keep : form.threshold ? .set : .clear

    let statAffinity = form.statAffinity != quest.statAffinity ? form.statAffinity : nil
    let duration = form.durationMinutes != quest.durationMinutes ? form.durationMinutes : nil
    guard !scheduleLocked else {
      patch = statAffinity == nil && duration == nil ? nil : try QuestSchedulePatch(durationMinutes: duration, statAffinity: statAffinity)
      return
    }
    let startTime: FieldChange<Int> =
      switch (form.startMinute, quest.startMinute) {
      case (let new, let old) where new == old: .keep
      case (.some(let minute), _): .set(minute)
      case (nil, _): .clear
      }
    let strictness = form.strictness != quest.strictness ? form.strictness : nil
    let newRecurrence = recurrence.flatMap { $0 == quest.recurrence ? nil : $0 }
    guard statAffinity != nil || duration != nil || startTime != .keep || strictness != nil || newRecurrence != nil else {
      patch = nil
      return
    }
    patch = try QuestSchedulePatch(
      strictness: strictness, startTimeMinutes: startTime, durationMinutes: duration, statAffinity: statAffinity,
      optionalStreakOptIn: strictness.map { $0 == .optional }, recurrence: newRecurrence)
  }
}
