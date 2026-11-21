import Foundation
import ShadowCore
import ShadowStore
import ShadowText

/// The closed set a suggestion may propose, each a field the owner can already edit on a quest (guardrails.ts:23).
public enum InsightSuggestionKind: String, CaseIterable, Hashable, Sendable {
  case shiftTime = "shift_time"
  case adjustDuration = "adjust_duration"
  case adjustStrictness = "adjust_strictness"
  case adjustReminder = "adjust_reminder"
  case pauseQuest = "pause_quest"
  case splitQuest = "split_quest"
}

/// An offer the owner may take by editing the quest themselves; nothing applies it.
public struct InsightSuggestion: Sendable, Hashable, StoredValue {
  public let kind: StoredChoice<InsightSuggestionKind>
  public let quest: UUID
  public let text: String

  public init(kind: StoredChoice<InsightSuggestionKind>, quest: UUID, text: String) {
    self.kind = kind
    self.quest = quest
    self.text = text
  }

  /// A suggestion the guardrails let through, read as the owner will see it; a quest id that is not a lower-case UUID names no quest of this vault.
  init?(_ draft: DraftSuggestion) {
    guard
      let name = draft.kind?.stringValue, let known = InsightSuggestionKind(rawValue: name), let questID = draft.questID.map(JSCoercion.string),
      let quest = UUID(uuidString: questID), quest.lowercasedString == questID
    else { return nil }
    self.init(kind: .known(known), quest: quest, text: draft.textOrEmpty)
  }

  public init?(stored: JSONValue) {
    guard
      let suggestion = MemberReader<InsightSuggestionMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) in InsightSuggestion(kind: try reader.required(.kind), quest: try reader.required(.quest), text: try reader.required(.text)) })
    else { return nil }
    self = suggestion
  }

  public var stored: JSONValue {
    var members = RecordMembers<InsightSuggestionMember>()
    members.put(.kind, kind)
    members.put(.quest, quest)
    members.put(.text, text)
    return members.json
  }
}

/// One answered insight, kept in the store of the highest class its context held. Its id derives from the job, so a step that ran again after storing it
/// finds it instead of asking the model twice; every field is first writer wins, and the owner can only dismiss it. It records no guardrail status, so a
/// crisis handoff leaves no mark in the owner's data (guardrails.ts:152-157).
public struct InsightRecord<Class: MetricClass>: IdentifiedRecord, RemovableMemoirRecord {
  public static var kind: MemoirKind { MemoirKind.insight(Class.syncClass) }
  public static var idDomain: String { "com.shadow.library.memoircore.insight" }

  public let id: UUID
  public var job: String
  public var question: String
  public var answer: String
  public var patterns: [String]
  public var suggestions: [InsightSuggestion]
  public var limitationNote: String?
  public var citations: [StoredChoice<InsightReadClass>]
  public var model: String
  public var promptVersion: String
  public var createdMillis: Int64

  public init(
    id: UUID, job: String, question: String, answer: String, patterns: [String], suggestions: [InsightSuggestion], limitationNote: String?,
    citations: [StoredChoice<InsightReadClass>], model: String, promptVersion: String, createdMillis: Int64
  ) {
    self.id = id
    self.job = job
    self.question = question
    self.answer = answer
    self.patterns = patterns
    self.suggestions = suggestions
    self.limitationNote = limitationNote
    self.citations = citations
    self.model = model
    self.promptVersion = promptVersion
    self.createdMillis = createdMillis
  }

  public init(id: UUID, reading reader: MemberReader<InsightField>) throws(MemoirUnreadable) {
    self.init(
      id: id, job: try reader.required(.job), question: try reader.required(.question), answer: try reader.required(.answer), patterns: try reader.required(.patterns),
      suggestions: try reader.required(.suggestions), limitationNote: try reader.optional(.limitationNote), citations: try reader.required(.citations),
      model: try reader.required(.model), promptVersion: try reader.required(.promptVersion), createdMillis: try reader.required(.createdMillis))
  }

  public static func id(forJob job: EntityRef) -> UUID {
    derivedID(idDomain, job.key.rawValue)
  }

  public var members: RecordMembers<InsightField> {
    var members = RecordMembers<InsightField>()
    members.put(.job, job)
    members.put(.question, question)
    members.put(.answer, answer)
    members.put(.patterns, patterns)
    members.put(.suggestions, suggestions)
    members.put(.limitationNote, limitationNote)
    members.put(.citations, citations)
    members.put(.model, model)
    members.put(.promptVersion, promptVersion)
    members.put(.createdMillis, createdMillis)
    return members
  }
}

/// The owner's one standing question, asked every night at `minuteOfDay` in the account's zone (ai_scheduled_queries; bootstrap.ts:124-125). It keeps the
/// local date and minute it was set at, so no night whose minute had already passed then is ever run for it.
public struct InsightScheduleRecord: NaturalKeyRecord {
  public static let kind = MemoirKind.insightSchedule
  public static let defaultMinuteOfDay = 120

  public var question: String
  public var active: Bool
  public var minuteOfDay: Int
  public var setOn: LocalDate
  public var setAtMinute: Int

  public init(question: String, active: Bool = true, minuteOfDay: Int = InsightScheduleRecord.defaultMinuteOfDay, setAt local: ZonedFields) {
    self.init(question: question, active: active, minuteOfDay: minuteOfDay, setOn: local.date, setAtMinute: local.minuteOfDay)
  }

  init(question: String, active: Bool, minuteOfDay: Int, setOn: LocalDate, setAtMinute: Int) {
    self.question = question
    self.active = active
    self.minuteOfDay = minuteOfDay
    self.setOn = setOn
    self.setAtMinute = setAtMinute
  }

  public init(key: MemoirKey, reading reader: MemberReader<InsightScheduleField>) throws(MemoirUnreadable) {
    guard case .insightSchedule = key else { throw .identity(key.ref) }
    self.init(
      question: try reader.required(.question), active: try reader.required(.active), minuteOfDay: try reader.required(.minuteOfDay), setOn: try reader.required(.setOn),
      setAtMinute: try reader.required(.setAtMinute))
  }

  public var key: MemoirKey { .insightSchedule }

  public var members: RecordMembers<InsightScheduleField> {
    var members = RecordMembers<InsightScheduleField>()
    members.put(.question, question)
    members.put(.active, active)
    members.put(.minuteOfDay, minuteOfDay)
    members.put(.setOn, setOn)
    members.put(.setAtMinute, setAtMinute)
    return members
  }
}
