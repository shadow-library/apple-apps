import Foundation
import ShadowCore

public enum QuestModuleLink: String, RuleKey {
  case journal
  case meal
  case weight
}

/// A patch field: left as it is, cleared, or set.
public enum FieldChange<Value: Sendable & Hashable>: Sendable, Hashable {
  case keep
  case clear
  case set(Value)
}

/// A text kept in the command's note record: the payload only says whether one is attached, cleared or left alone.
public enum TextChange: Sendable, Hashable {
  case keep
  case clear
  case set
}

/// A quest's schedule and strictness, everything of `parseQuestDraft` but the owner's words and reminder (those are `QuestRecord`) and the health
/// threshold, which waits for a record kind of its own.
public struct QuestSchedule: Sendable, Hashable {
  static let recurrenceIntegerPaths: Set<String> = ["interval", "end.count", "daysOfWeek[]", "pattern.dayOfMonth", "pattern.weekday", "pattern.ordinal"]
  static let integerPaths: Set<String> = Set(["startTimeMinutes", "durationMinutes"] + recurrenceIntegerPaths.map { "recurrence.\($0)" })

  public let strictness: Strictness
  public let startTimeMinutes: Int?
  public let durationMinutes: Int
  public let statAffinity: StatAffinity
  public let optionalStreakOptIn: Bool
  public let recurrence: RecurrenceRule
  public let moduleLink: QuestModuleLink?
  public let active: Bool

  public init(
    strictness: Strictness, startTimeMinutes: Int? = nil, durationMinutes: Int = 0, statAffinity: StatAffinity, optionalStreakOptIn: Bool = false,
    recurrence: RecurrenceRule, moduleLink: QuestModuleLink? = nil, active: Bool = true
  ) throws(CommandRefusal) {
    if let startTimeMinutes { try PayloadReader.checkMinute(startTimeMinutes, field: "startTimeMinutes") }
    if strictness == .anchor && startTimeMinutes == nil { throw .anchorNeedsStartTime }
    self.strictness = strictness
    self.startTimeMinutes = startTimeMinutes
    self.durationMinutes = durationMinutes
    self.statAffinity = statAffinity
    self.optionalStreakOptIn = optionalStreakOptIn
    self.recurrence = recurrence
    self.moduleLink = moduleLink
    self.active = active
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let strictness = try reader.choice("strictness", as: Strictness.self)
    let startTimeMinutes = try reader.present("startTimeMinutes").map { value throws(CommandRefusal) in try PayloadReader.minuteOfDay(value, field: "startTimeMinutes") }
    let durationMinutes = try reader.present("durationMinutes").map { value throws(CommandRefusal) in try PayloadReader.integer(value, field: "durationMinutes") } ?? 0
    let statAffinity = try reader.choice("statAffinity", as: StatAffinity.self)
    let optionalStreakOptIn = try reader.bool("optionalStreakOptIn", default: false)
    var recurrenceReader = try reader.object("recurrence")
    let recurrence = try QuestRecurrenceCoding.read(&recurrenceReader)
    let moduleLink = try reader.optionalChoice("moduleLink", as: QuestModuleLink.self)
    if reader.contains("healthThreshold") { throw .healthThresholdUnsupported }
    let active = try reader.bool("active", default: true)
    try self.init(
      strictness: strictness, startTimeMinutes: startTimeMinutes, durationMinutes: durationMinutes, statAffinity: statAffinity, optionalStreakOptIn: optionalStreakOptIn,
      recurrence: recurrence, moduleLink: moduleLink, active: active)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("strictness", token: strictness)
    writer.put("startTimeMinutes", startTimeMinutes)
    writer.put("durationMinutes", durationMinutes)
    writer.put("statAffinity", token: statAffinity)
    writer.put("optionalStreakOptIn", optionalStreakOptIn)
    writer.put("recurrence", QuestRecurrenceCoding.writer(for: recurrence))
    writer.put("moduleLink", token: moduleLink)
    writer.put("active", active)
  }
}

/// `parseQuestPatch`, applied over the quest's current schedule. An anchor without a start time is refused here only when the patch itself clears the
/// start time; whether the quest's current start time is missing is for replay to judge.
public struct QuestSchedulePatch: Sendable, Hashable {
  public let strictness: Strictness?
  public let startTimeMinutes: FieldChange<Int>
  public let durationMinutes: Int?
  public let statAffinity: StatAffinity?
  public let optionalStreakOptIn: Bool?
  public let recurrence: RecurrenceRule?
  public let moduleLink: FieldChange<QuestModuleLink>
  public let active: Bool?

  public init(
    strictness: Strictness? = nil, startTimeMinutes: FieldChange<Int> = .keep, durationMinutes: Int? = nil, statAffinity: StatAffinity? = nil,
    optionalStreakOptIn: Bool? = nil, recurrence: RecurrenceRule? = nil, moduleLink: FieldChange<QuestModuleLink> = .keep, active: Bool? = nil
  ) throws(CommandRefusal) {
    if case .set(let minute) = startTimeMinutes { try PayloadReader.checkMinute(minute, field: "startTimeMinutes") }
    if strictness == .anchor && startTimeMinutes == .clear { throw .anchorNeedsStartTime }
    self.strictness = strictness
    self.startTimeMinutes = startTimeMinutes
    self.durationMinutes = durationMinutes
    self.statAffinity = statAffinity
    self.optionalStreakOptIn = optionalStreakOptIn
    self.recurrence = recurrence
    self.moduleLink = moduleLink
    self.active = active
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    var startTimeMinutes = FieldChange<Int>.keep
    if let value = reader.value("startTimeMinutes") {
      startTimeMinutes = value.isNull ? .clear : .set(try PayloadReader.minuteOfDay(value, field: "startTimeMinutes"))
    }
    let durationMinutes = try reader.value("durationMinutes").map { value throws(CommandRefusal) in try PayloadReader.integer(value, field: "durationMinutes") }
    let statAffinity = try reader.value("statAffinity").map { value throws(CommandRefusal) -> StatAffinity in try PayloadReader.choice(value, field: "statAffinity") }
    let strictness = try reader.value("strictness").map { value throws(CommandRefusal) -> Strictness in try PayloadReader.choice(value, field: "strictness") }
    let optionalStreakOptIn = reader.contains("optionalStreakOptIn") ? try reader.bool("optionalStreakOptIn", default: false) : nil
    var recurrence: RecurrenceRule?
    if reader.contains("recurrence") {
      var recurrenceReader = try reader.object("recurrence")
      recurrence = try QuestRecurrenceCoding.read(&recurrenceReader)
    }
    var moduleLink = FieldChange<QuestModuleLink>.keep
    if let value = reader.value("moduleLink") {
      moduleLink = value.isNull ? .clear : .set(try PayloadReader.choice(value, field: "moduleLink"))
    }
    if reader.contains("healthThreshold") { throw .healthThresholdUnsupported }
    let active = reader.contains("active") ? try reader.bool("active", default: true) : nil
    try self.init(
      strictness: strictness, startTimeMinutes: startTimeMinutes, durationMinutes: durationMinutes, statAffinity: statAffinity, optionalStreakOptIn: optionalStreakOptIn,
      recurrence: recurrence, moduleLink: moduleLink, active: active)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("strictness", token: strictness)
    switch startTimeMinutes {
    case .keep: break
    case .clear: writer.putNull("startTimeMinutes")
    case .set(let minute): writer.put("startTimeMinutes", minute)
    }
    writer.put("durationMinutes", durationMinutes)
    writer.put("statAffinity", token: statAffinity)
    writer.put("optionalStreakOptIn", optionalStreakOptIn)
    if let recurrence { writer.put("recurrence", QuestRecurrenceCoding.writer(for: recurrence)) }
    switch moduleLink {
    case .keep: break
    case .clear: writer.putNull("moduleLink")
    case .set(let link): writer.put("moduleLink", token: link)
    }
    writer.put("active", active)
  }
}

/// The reference's `RecurrenceRule` wire shape (`parseRecurrence`), read into the native rule. A monthly day below 1 is refused here, where the
/// reference accepts it and later produces dates that do not exist.
enum QuestRecurrenceCoding {
  private enum Frequency: String, RuleKey {
    case daily
    case weekly
    case monthly
    case yearly
  }

  private enum EndKind: String, RuleKey {
    case never
    case count
    case until
  }

  private enum PatternKind: String, RuleKey {
    case dayOfMonth = "day_of_month"
    case nthWeekday = "nth_weekday"
  }

  static func read(_ reader: inout PayloadReader) throws(CommandRefusal) -> RecurrenceRule {
    let frequency = try reader.choice("frequency", as: Frequency.self)
    let interval = reader.contains("interval") ? try reader.integer("interval") : 1
    let startDate = try reader.date("startDate")
    var endReader = try reader.object("end")
    let end = try readEnd(&endReader)
    let exceptions = try readExceptions(&reader)
    let ruleFrequency: RecurrenceRule.Frequency
    switch frequency {
    case .daily: ruleFrequency = .daily
    case .weekly: ruleFrequency = .weekly(try readWeekdays(&reader))
    case .monthly:
      var patternReader = try reader.object("pattern")
      ruleFrequency = .monthly(try readPattern(&patternReader))
    case .yearly: ruleFrequency = .yearly
    }
    try reader.finish()
    do throws(CalendarError) {
      return try RecurrenceRule(frequency: ruleFrequency, interval: interval, startDate: startDate, end: end, exceptions: exceptions)
    } catch {
      throw .calendar(field: calendarField(error, reader: reader), error)
    }
  }

  static func writer(for rule: RecurrenceRule) -> PayloadWriter {
    var writer = PayloadWriter()
    writer.put("interval", rule.interval)
    writer.put("startDate", rule.startDate)
    var end = PayloadWriter()
    switch rule.end {
    case .never:
      end.put("kind", token: EndKind.never)
    case .count(let count):
      end.put("kind", token: EndKind.count)
      end.put("count", count)
    case .until(let date):
      end.put("kind", token: EndKind.until)
      end.put("date", date)
    }
    writer.put("end", end)
    if !rule.exceptions.isEmpty { writer.put("exceptions", rule.exceptions.sorted()) }
    switch rule.frequency {
    case .daily:
      writer.put("frequency", token: Frequency.daily)
    case .weekly(let weekdays):
      writer.put("frequency", token: Frequency.weekly)
      writer.put("daysOfWeek", weekdays.map(\.rawValue).sorted())
    case .monthly(let pattern):
      writer.put("frequency", token: Frequency.monthly)
      var patternWriter = PayloadWriter()
      switch pattern {
      case .dayOfMonth(let day):
        patternWriter.put("kind", token: PatternKind.dayOfMonth)
        patternWriter.put("dayOfMonth", day)
      case .nthWeekday(let weekday, let ordinal):
        patternWriter.put("kind", token: PatternKind.nthWeekday)
        patternWriter.put("weekday", weekday.rawValue)
        patternWriter.put("ordinal", json: ordinalJSON(ordinal))
      }
      writer.put("pattern", patternWriter)
    case .yearly:
      writer.put("frequency", token: Frequency.yearly)
    }
    return writer
  }

  private static func calendarField(_ error: CalendarError, reader: PayloadReader) -> String {
    switch error {
    case .noWeekdays: reader.field("daysOfWeek")
    case .dayOfMonthOutOfRange: reader.field("pattern.dayOfMonth")
    case .dateOutOfRange, .minuteOfDayOutOfRange, .billingDayOutOfRange: reader.field("frequency")
    }
  }

  private static func readEnd(_ reader: inout PayloadReader) throws(CommandRefusal) -> RecurrenceEnd {
    let end: RecurrenceEnd
    switch try reader.choice("kind", as: EndKind.self) {
    case .never: end = .never
    case .count: end = .count(try reader.integer("count"))
    case .until: end = .until(try reader.date("date"))
    }
    try reader.finish()
    return end
  }

  private static func readExceptions(_ reader: inout PayloadReader) throws(CommandRefusal) -> Set<LocalDate> {
    guard let value = reader.value("exceptions") else { return [] }
    guard let entries = value.arrayValue else { throw .invalidField(field: reader.field("exceptions"), problem: .notArray) }
    var dates = Set<LocalDate>()
    for (index, entry) in entries.enumerated() {
      let field = reader.field("exceptions.\(index)")
      guard let text = entry.stringValue, !text.isEmpty else { throw .invalidField(field: field, problem: .required) }
      dates.insert(try PayloadReader.date(text, field: field))
    }
    return dates
  }

  private static func readWeekdays(_ reader: inout PayloadReader) throws(CommandRefusal) -> Set<LocalDate.Weekday> {
    guard let entries = reader.value("daysOfWeek")?.arrayValue, !entries.isEmpty else { throw .invalidField(field: reader.field("daysOfWeek"), problem: .required) }
    var weekdays = Set<LocalDate.Weekday>()
    for (index, entry) in entries.enumerated() {
      weekdays.insert(try weekday(entry, field: reader.field("daysOfWeek.\(index)")))
    }
    return weekdays
  }

  private static func readPattern(_ reader: inout PayloadReader) throws(CommandRefusal) -> MonthlyPattern {
    let pattern: MonthlyPattern
    switch try reader.choice("kind", as: PatternKind.self) {
    case .dayOfMonth:
      pattern = .dayOfMonth(try reader.integer("dayOfMonth"))
    case .nthWeekday:
      let weekday = try weekday(reader.value("weekday") ?? .null, field: reader.field("weekday"))
      pattern = .nthWeekday(weekday, try ordinal(reader.value("ordinal") ?? .null, field: reader.field("ordinal")))
    }
    try reader.finish()
    return pattern
  }

  private static func weekday(_ value: JSONValue, field: String) throws(CommandRefusal) -> LocalDate.Weekday {
    guard let number = value.intValue, let weekday = Int(exactly: number).flatMap(LocalDate.Weekday.init(rawValue:)) else {
      throw .invalidField(field: field, problem: .notAllowed)
    }
    return weekday
  }

  private static func ordinal(_ value: JSONValue, field: String) throws(CommandRefusal) -> WeekdayOrdinal {
    switch value {
    case .int(1): .first
    case .int(2): .second
    case .int(3): .third
    case .int(4): .fourth
    case .string("last"): .last
    default: throw .invalidField(field: field, problem: .notAllowed)
    }
  }

  private static func ordinalJSON(_ ordinal: WeekdayOrdinal) -> JSONValue {
    switch ordinal {
    case .first: .int(1)
    case .second: .int(2)
    case .third: .int(3)
    case .fourth: .int(4)
    case .last: .string("last")
    }
  }
}

public struct QuestCreation: Sendable, Hashable {
  public let questId: UUID
  public let schedule: QuestSchedule

  public init(questId: UUID, schedule: QuestSchedule) {
    self.questId = questId
    self.schedule = schedule
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let questId = try reader.uuid("questId")
    self.init(questId: questId, schedule: try QuestSchedule(reading: &reader))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("questId", questId)
    schedule.write(to: &writer)
  }
}

public struct QuestUpdate: Sendable, Hashable {
  public let questId: UUID
  public let patch: QuestSchedulePatch

  public init(questId: UUID, patch: QuestSchedulePatch) {
    self.questId = questId
    self.patch = patch
  }

  /// The reference reads `payload.patch ?? {}` without checking its shape and names the patch's fields without a `patch.` prefix.
  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let questId = try reader.uuid("questId")
    var patchReader = PayloadReader([:])
    if let value = reader.present("patch") {
      guard let members = value.objectValue else { throw .invalidField(field: "patch", problem: .notObject) }
      patchReader = PayloadReader(members)
    }
    let patch = try QuestSchedulePatch(reading: &patchReader)
    try patchReader.finish()
    self.init(questId: questId, patch: patch)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("questId", questId)
    var patchWriter = PayloadWriter()
    patch.write(to: &patchWriter)
    writer.put("patch", patchWriter)
  }
}

public struct QuestReference: Sendable, Hashable {
  public let questId: UUID

  public init(questId: UUID) {
    self.questId = questId
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    self.init(questId: try reader.uuid("questId"))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("questId", questId)
  }
}

/// `true` under `note` or `reflectionText` says the text is in the command's note record; `null` (only in a log edit) clears it.
enum AttachedText {
  static func read(_ key: String, from reader: inout PayloadReader, allowsClear: Bool) throws(CommandRefusal) -> TextChange {
    guard let value = reader.value(key) else { return .keep }
    switch value {
    case .bool(true): return .set
    case .null: return allowsClear ? .clear : .keep
    default: throw .invalidField(field: reader.field(key), problem: .notAllowed)
    }
  }

  static func write(_ change: TextChange, _ key: String, to writer: inout PayloadWriter) {
    switch change {
    case .keep: break
    case .clear: writer.putNull(key)
    case .set: writer.put(key, true)
    }
  }
}

/// A skip or a postpone; the reason note's text, when `hasNote`, is the command's note record.
public struct QuestBreak: Sendable, Hashable {
  public let occurrence: Occurrence
  public let reasonTag: ReasonTag?
  public let hasNote: Bool

  public init(occurrence: Occurrence, reasonTag: ReasonTag? = nil, hasNote: Bool = false) {
    self.occurrence = occurrence
    self.reasonTag = reasonTag
    self.hasNote = hasNote
  }

  init(reading reader: inout PayloadReader, occurrence: Occurrence) throws(CommandRefusal) {
    let reasonTag = try reader.optionalChoice("reasonTag", as: ReasonTag.self)
    self.init(occurrence: occurrence, reasonTag: reasonTag, hasNote: try AttachedText.read("note", from: &reader, allowsClear: false) == .set)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("reasonTag", token: reasonTag)
    AttachedText.write(hasNote ? .set : .keep, "note", to: &writer)
  }
}

/// The occurrence's new start minute; `acceptBeyondCap` turns a reschedule past the weekly cap into a postpone, which replay decides.
public struct QuestReschedule: Sendable, Hashable {
  public let occurrence: Occurrence
  public let toMinute: Int
  public let acceptBeyondCap: Bool
  public let reasonTag: ReasonTag?
  public let hasNote: Bool

  public init(occurrence: Occurrence, toMinute: Int, acceptBeyondCap: Bool = false, reasonTag: ReasonTag? = nil, hasNote: Bool = false) throws(CommandRefusal) {
    self.occurrence = occurrence
    try PayloadReader.checkMinute(toMinute, field: "toMin")
    self.toMinute = toMinute
    self.acceptBeyondCap = acceptBeyondCap
    self.reasonTag = reasonTag
    self.hasNote = hasNote
  }

  init(reading reader: inout PayloadReader, occurrence: Occurrence) throws(CommandRefusal) {
    let toMinute = try PayloadReader.minuteOfDay(reader.value("toMin") ?? .null, field: "toMin")
    let acceptBeyondCap = try reader.bool("acceptBeyondCap", default: false)
    let reasonTag = try reader.optionalChoice("reasonTag", as: ReasonTag.self)
    let hasNote = try AttachedText.read("note", from: &reader, allowsClear: false) == .set
    try self.init(occurrence: occurrence, toMinute: toMinute, acceptBeyondCap: acceptBeyondCap, reasonTag: reasonTag, hasNote: hasNote)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("toMin", toMinute)
    writer.put("acceptBeyondCap", acceptBeyondCap)
    writer.put("reasonTag", token: reasonTag)
    AttachedText.write(hasNote ? .set : .keep, "note", to: &writer)
  }
}

/// A reason attached to an occurrence's log after the fact: a tag, a note, or both, never neither.
public struct QuestReason: Sendable, Hashable {
  public let occurrence: Occurrence
  public let reasonTag: ReasonTag?
  public let hasNote: Bool

  public init(occurrence: Occurrence, reasonTag: ReasonTag?, hasNote: Bool) throws(CommandRefusal) {
    guard reasonTag != nil || hasNote else { throw .invalidField(field: "reasonTag", problem: .required) }
    self.occurrence = occurrence
    self.reasonTag = reasonTag
    self.hasNote = hasNote
  }

  init(reading reader: inout PayloadReader, occurrence: Occurrence) throws(CommandRefusal) {
    let reasonTag = try reader.optionalChoice("reasonTag", as: ReasonTag.self)
    try self.init(occurrence: occurrence, reasonTag: reasonTag, hasNote: try AttachedText.read("note", from: &reader, allowsClear: false) == .set)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("reasonTag", token: reasonTag)
    AttachedText.write(hasNote ? .set : .keep, "note", to: &writer)
  }
}

/// A command keeps one text, so a log edit sets the reason note or the reflection, not both.
public struct QuestLogEdit: Sendable, Hashable {
  public let occurrence: Occurrence
  public let reasonTag: FieldChange<ReasonTag>
  public let note: TextChange
  public let reflection: TextChange

  public init(occurrence: Occurrence, reasonTag: FieldChange<ReasonTag> = .keep, note: TextChange = .keep, reflection: TextChange = .keep) throws(CommandRefusal) {
    guard !(note == .set && reflection == .set) else { throw .oneTextPerCommand }
    self.occurrence = occurrence
    self.reasonTag = reasonTag
    self.note = note
    self.reflection = reflection
  }

  init(reading reader: inout PayloadReader, occurrence: Occurrence) throws(CommandRefusal) {
    var reasonTag = FieldChange<ReasonTag>.keep
    if let value = reader.value("reasonTag") {
      reasonTag = value.isNull ? .clear : .set(try PayloadReader.choice(value, field: "reasonTag"))
    }
    let note = try AttachedText.read("note", from: &reader, allowsClear: true)
    let reflection = try AttachedText.read("reflectionText", from: &reader, allowsClear: true)
    try self.init(occurrence: occurrence, reasonTag: reasonTag, note: note, reflection: reflection)
  }

  func write(to writer: inout PayloadWriter) {
    switch reasonTag {
    case .keep: break
    case .clear: writer.putNull("reasonTag")
    case .set(let tag): writer.put("reasonTag", token: tag)
    }
    AttachedText.write(note, "note", to: &writer)
    AttachedText.write(reflection, "reflectionText", to: &writer)
  }
}
