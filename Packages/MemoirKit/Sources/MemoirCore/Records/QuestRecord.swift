import Foundation

/// The owner's words for a quest. Its strictness, schedule, deletion and every action on it are commands; replay derives the rest.
public struct QuestRecord: IdentifiedRecord {
  public static let kind = MemoirKind.quest

  public let id: UUID
  public var name: String
  public var notes: String?
  public var reminderEnabled: Bool
  public var reminderLeadMinutes: Int

  public init(id: UUID, name: String, notes: String? = nil, reminderEnabled: Bool = false, reminderLeadMinutes: Int = 0) {
    self.id = id
    self.name = name
    self.notes = notes
    self.reminderEnabled = reminderEnabled
    self.reminderLeadMinutes = reminderLeadMinutes
  }

  public init(id: UUID, reading reader: MemberReader<QuestField>) throws(MemoirUnreadable) {
    self.init(
      id: id, name: try reader.required(.name), notes: try reader.optional(.notes), reminderEnabled: try reader.required(.reminderEnabled),
      reminderLeadMinutes: try reader.required(.reminderLeadMinutes))
  }

  public var members: RecordMembers<QuestField> {
    var members = RecordMembers<QuestField>()
    members.put(.name, name)
    members.put(.notes, notes)
    members.put(.reminderEnabled, reminderEnabled)
    members.put(.reminderLeadMinutes, reminderLeadMinutes)
    return members
  }
}
