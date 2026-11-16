import Foundation
import ShadowCore
import ShadowStore

extension MilestoneField: FieldName {}

public struct MilestoneRecord: RemovableRecord {
  public static let kind = NovelForgeKind.milestone

  public let key: NovelForgeKey
  public let milestone: String
  public var label: String
  public var subject: String?
  public var kind: StoredEnum<MilestoneKind>

  public init(novel: UUID, milestone: String, label: String, subject: String? = nil, kind: StoredEnum<MilestoneKind> = .known(.custom)) {
    let milestone = milestone.precomposedStringWithCanonicalMapping
    self.milestone = milestone
    key = .milestoneKey(novel: novel, milestone: milestone)
    self.label = label
    self.subject = subject
    self.kind = kind
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<MilestoneField>) throws(UnreadableReason) {
    guard case .milestone(let milestone) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(
      novel: key.novel, milestone: milestone, label: try reader.required(.label), subject: try reader.optional(.subject), kind: try reader.required(.kind))
  }

  public var fields: RecordFields<MilestoneField> {
    var fields = RecordFields<MilestoneField>()
    fields.put(.label, label)
    fields.put(.subject, subject)
    fields.put(.kind, kind)
    return fields
  }
}

public struct MilestoneEdit: Sendable, Equatable {
  public var label: FieldChange<String> = .keep
  public var subject: FieldChange<String?> = .keep
  public var kind: FieldChange<StoredEnum<MilestoneKind>> = .keep

  public init() {}

  public var fields: RecordFields<MilestoneField> {
    var fields = RecordFields<MilestoneField>()
    fields.put(.label, label)
    fields.put(.subject, subject)
    fields.put(.kind, kind)
    return fields
  }
}

extension MilestoneRecord {
  public static func ref(novel: UUID, milestone: String) -> EntityRef { NovelForgeKey.milestone(novel: novel, key: milestone) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, milestone: String, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<
    MilestoneRecord
  > {
    try read(ref(novel: novel, milestone: milestone), in: transaction)
  }

  public static func edit(novel: UUID, milestone: String, _ changes: MilestoneEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(novel: novel, milestone: milestone), changes.fields, in: &transaction)
  }

  public static func remove(novel: UUID, milestone: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, milestone: milestone), in: &transaction)
  }
}
