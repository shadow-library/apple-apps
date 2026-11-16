import Foundation
import ShadowCore
import ShadowStore

public struct MilestoneChanges: Sendable, Equatable {
  public var label: String?
  public var subject: FieldChange<String?> = .keep
  public var kind: StoredEnum<MilestoneKind>?

  public init(label: String? = nil, subject: FieldChange<String?> = .keep, kind: StoredEnum<MilestoneKind>? = nil) {
    self.label = label
    self.subject = subject
    self.kind = kind
  }

  var isEmpty: Bool { label == nil && subject == .keep && kind == nil }
}

// apps/novel-forge-server/src/modules/bible/milestone/milestone.dto.ts:28,31 and database/schemas/knowledge.ts:211
private let milestoneKeyLimit = 200
private let milestoneLabelLimit = 500

// apps/novel-forge-server/src/modules/bible/milestone/milestone.service.ts; the state of a milestone is derived from plans and chapters, never set here
public enum Milestones {
  // milestone.service.ts:27
  public static func create(
    novel: UUID, milestone: String, label: String, subject: String? = nil, kind: StoredEnum<MilestoneKind> = .known(.custom), in transaction: inout WriteTransaction
  ) throws(StoryError) {
    try requireSpacelessKey(milestone, field: "milestoneKey")
    try requireAtMost(milestone, milestoneKeyLimit, field: "milestoneKey")
    try requireNonBlank(label, field: "label")
    try requireAtMost(label.jsTrim(), milestoneLabelLimit, field: "label")
    try requireKnown(kind)
    try transaction.requireNovel(novel)
    let subject = trimmedOrNil(subject)
    if let subject { try requireSubject(novel: novel, subject, in: transaction) }
    let record = MilestoneRecord(novel: novel, milestone: milestone, label: label.jsTrim(), subject: subject, kind: kind)
    if case .live = try transaction.presence(record.ref, as: MilestoneRecord.self) { throw .milestoneExists(record.milestone) }
    try transaction.create(record)
  }

  // milestone.service.ts:42
  public static func edit(novel: UUID, milestone: String, _ changes: MilestoneChanges, in transaction: inout WriteTransaction) throws(StoryError) {
    try requireSpacelessKey(milestone, field: "milestoneKey")
    guard !changes.isEmpty else { throw .noChanges }
    if let label = changes.label {
      try requireNonBlank(label, field: "label")
      try requireAtMost(label.jsTrim(), milestoneLabelLimit, field: "label")
    }
    if let kind = changes.kind { try requireKnown(kind) }
    var edit = MilestoneEdit()
    if let label = changes.label { edit.label = .set(label.jsTrim()) }
    if case .set(let subject) = changes.subject {
      let subject = trimmedOrNil(subject)
      if let subject { try requireSubject(novel: novel, subject, in: transaction) }
      edit.subject = .set(subject)
    }
    if let kind = changes.kind { edit.kind = .set(kind) }
    let ref = MilestoneRecord.ref(novel: novel, milestone: milestone)
    guard case .live = try transaction.presence(ref, as: MilestoneRecord.self) else { throw .milestoneNotFound(milestone) }
    try transaction.edit(MilestoneRecord.self, ref, edit.fields)
  }

  // milestone.service.ts:57
  public static func remove(novel: UUID, milestone: String, in transaction: inout WriteTransaction) throws(StoryError) {
    let ref = MilestoneRecord.ref(novel: novel, milestone: milestone)
    let key = milestone.precomposedStringWithCanonicalMapping
    let references = try references(to: key, novel: novel, in: transaction)
    guard references.isEmpty else { throw .milestoneReferenced(milestone: key, references: references) }
    guard case .live = try transaction.presence(ref, as: MilestoneRecord.self) else { throw .milestoneNotFound(milestone) }
    try transaction.remove(MilestoneRecord.self, ref)
  }

  public static func restore(novel: UUID, milestone: String, in transaction: inout WriteTransaction) throws(StoryError) {
    switch try transaction.presence(MilestoneRecord.ref(novel: novel, milestone: milestone), as: MilestoneRecord.self) {
    case .removed(let record): try transaction.restore(record)
    case .live: return
    case .absent: throw .milestoneNotFound(milestone)
    }
  }

  // apps/novel-forge-server/src/common/plan-state.ts:152
  static func references(to milestone: String, novel: UUID, in transaction: borrowing WriteTransaction) throws(StoryError) -> [String] {
    let claiming = try transaction.listing(ChapterPlanRecord.self, novel: novel)
      .filter { $0.content.contract.claimedMilestones.contains { $0.jsEquals(milestone) } }
      .map(\.chapter)
      .sorted()
      .map { "the plan for chapter \($0)" }
    let unlocking = try transaction.listing(SecretRecord.self, novel: novel)
      .filter { secret in secret.unlock.map { unlockNames(milestone, in: $0) } ?? false }
      .map { "the unlock of fact \($0.secret)" }
      .jsSorted()
    return claiming + unlocking
  }

  private static func unlockNames(_ milestone: String, in unlock: JSONValue) -> Bool {
    let condition = OrderedJSON(unlock)
    guard isUnlockCondition(condition), let terms = condition.objectValue?["all"]?.arrayValue else { return false }
    return terms.contains { $0.objectValue?["milestone"]?.stringValue?.jsEquals(milestone) == true }
  }

  private static func requireKnown(_ kind: StoredEnum<MilestoneKind>) throws(StoryError) {
    guard case .unknown(let raw) = kind else { return }
    throw .unknownKind(raw)
  }

  // plan-state.ts:146
  private static func requireSubject(novel: UUID, _ subject: String, in transaction: borrowing WriteTransaction) throws(StoryError) {
    guard case .live = try transaction.presence(EntityRecord.ref(novel: novel, entity: subject), as: EntityRecord.self) else { throw .milestoneSubjectUnknown(subject) }
  }
}

func trimmedOrNil(_ text: String?) -> String? {
  guard let trimmed = text?.jsTrim(), !trimmed.isEmpty else { return nil }
  return trimmed
}
