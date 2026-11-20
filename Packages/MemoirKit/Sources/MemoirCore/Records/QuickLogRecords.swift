import Foundation
import ShadowCore

/// The text is a revision body, so concurrent edits on two devices both survive: the losing head stays a version the owner can restore.
public struct JournalEntryRecord: IdentifiedRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.journalEntry

  public let id: UUID
  public var date: LocalDate
  public var text: String
  public var mood: Int?
  public var tags: [String]
  public var loggedAtMillis: Int64

  public init(id: UUID, date: LocalDate, text: String, mood: Int? = nil, tags: [String] = [], loggedAtMillis: Int64) {
    self.id = id
    self.date = date
    self.text = text
    self.mood = mood
    self.tags = tags
    self.loggedAtMillis = loggedAtMillis
  }

  public init(id: UUID, reading reader: MemberReader<JournalEntryField>) throws(MemoirUnreadable) {
    guard let body = reader.body else { throw .missing(field: JournalBodyMember.text.rawValue) }
    guard let text = MemberReader<JournalBodyMember>.nested(body, { body throws(MemoirUnreadable) -> String in try body.required(.text) }) else {
      throw .invalid(field: JournalBodyMember.text.rawValue)
    }
    self.init(
      id: id, date: try reader.required(.date), text: text, mood: try reader.optional(.mood), tags: try reader.required(.tags),
      loggedAtMillis: try reader.required(.loggedAtMillis))
  }

  public var members: RecordMembers<JournalEntryField> {
    var members = RecordMembers<JournalEntryField>()
    members.put(.date, date)
    members.put(.mood, mood)
    members.put(.tags, tags)
    members.put(.loggedAtMillis, loggedAtMillis)
    return members
  }

  public var body: JSONValue? {
    var body = RecordMembers<JournalBodyMember>()
    body.put(.text, text)
    return body.json
  }
}

public enum MealType: String, CaseIterable, Hashable, Sendable {
  case cooked
  case ateOut = "ate_out"
}

public struct MealRecord: IdentifiedRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.meal

  public let id: UUID
  public var date: LocalDate
  public var name: String
  public var calories: Int
  public var mealType: StoredChoice<MealType>
  public var note: String?
  public var preset: UUID?
  public var loggedAtMillis: Int64

  public init(
    id: UUID, date: LocalDate, name: String, calories: Int, mealType: StoredChoice<MealType>, note: String? = nil, preset: UUID? = nil, loggedAtMillis: Int64
  ) {
    self.id = id
    self.date = date
    self.name = name
    self.calories = calories
    self.mealType = mealType
    self.note = note
    self.preset = preset
    self.loggedAtMillis = loggedAtMillis
  }

  public init(id: UUID, reading reader: MemberReader<MealField>) throws(MemoirUnreadable) {
    self.init(
      id: id, date: try reader.required(.date), name: try reader.required(.name), calories: try reader.required(.calories), mealType: try reader.required(.mealType),
      note: try reader.optional(.note), preset: try reader.optional(.preset), loggedAtMillis: try reader.required(.loggedAtMillis))
  }

  public var members: RecordMembers<MealField> {
    var members = RecordMembers<MealField>()
    members.put(.date, date)
    members.put(.name, name)
    members.put(.calories, calories)
    members.put(.mealType, mealType)
    members.put(.note, note)
    members.put(.preset, preset)
    members.put(.loggedAtMillis, loggedAtMillis)
    return members
  }
}

public struct MealPresetRecord: IdentifiedRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.mealPreset

  public let id: UUID
  public var name: String
  public var calories: Int
  public var mealType: StoredChoice<MealType>
  public var note: String?

  public init(id: UUID, name: String, calories: Int, mealType: StoredChoice<MealType>, note: String? = nil) {
    self.id = id
    self.name = name
    self.calories = calories
    self.mealType = mealType
    self.note = note
  }

  public init(id: UUID, reading reader: MemberReader<MealPresetField>) throws(MemoirUnreadable) {
    self.init(
      id: id, name: try reader.required(.name), calories: try reader.required(.calories), mealType: try reader.required(.mealType), note: try reader.optional(.note))
  }

  public var members: RecordMembers<MealPresetField> {
    var members = RecordMembers<MealPresetField>()
    members.put(.name, name)
    members.put(.calories, calories)
    members.put(.mealType, mealType)
    members.put(.note, note)
    return members
  }
}

/// The owner's words for a completed one-off act; its reward and stat come from the command that logged it.
public struct SideQuestRecord: IdentifiedRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.sideQuest

  public let id: UUID
  public var date: LocalDate
  public var name: String
  public var loggedAtMillis: Int64

  public init(id: UUID, date: LocalDate, name: String, loggedAtMillis: Int64) {
    self.id = id
    self.date = date
    self.name = name
    self.loggedAtMillis = loggedAtMillis
  }

  public init(id: UUID, reading reader: MemberReader<SideQuestField>) throws(MemoirUnreadable) {
    self.init(id: id, date: try reader.required(.date), name: try reader.required(.name), loggedAtMillis: try reader.required(.loggedAtMillis))
  }

  public var members: RecordMembers<SideQuestField> {
    var members = RecordMembers<SideQuestField>()
    members.put(.date, date)
    members.put(.name, name)
    members.put(.loggedAtMillis, loggedAtMillis)
    return members
  }
}

/// Health class: lives only in the restricted store. One value per day; logging the day again replaces it.
public struct WeightRecord: NaturalKeyRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.weight

  public let date: LocalDate
  public var kilograms: DecimalText
  public var loggedAtMillis: Int64

  public init(date: LocalDate, kilograms: DecimalText, loggedAtMillis: Int64) {
    self.date = date
    self.kilograms = kilograms
    self.loggedAtMillis = loggedAtMillis
  }

  public init(key: MemoirKey, reading reader: MemberReader<WeightField>) throws(MemoirUnreadable) {
    guard case .weight(let date) = key else { throw .identity(key.ref) }
    self.init(date: date, kilograms: try reader.required(.kilograms), loggedAtMillis: try reader.required(.loggedAtMillis))
  }

  public var key: MemoirKey { .weight(date) }

  public var members: RecordMembers<WeightField> {
    var members = RecordMembers<WeightField>()
    members.put(.kilograms, kilograms)
    members.put(.loggedAtMillis, loggedAtMillis)
    return members
  }
}
