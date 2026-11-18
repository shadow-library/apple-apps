import Foundation
import ShadowCore
import ShadowStore

extension ReviewRemedyField: FieldName {}
extension ReviewRemedyMember: FieldName {}

// apps/novel-forge-server/src/database/schemas/review.ts:75-90
public struct ReviewRemedy: Sendable, Equatable {
  public var action: StoredEnum<ReviewRemedyAction>
  public var fingerprint: String
  public var reason: String?
  public private(set) var unrecognised: [String: JSONValue]

  public init(action: StoredEnum<ReviewRemedyAction>, fingerprint: String, reason: String? = nil) {
    self.action = action
    self.fingerprint = fingerprint
    self.reason = reason
    unrecognised = [:]
  }
}

extension ReviewRemedy: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ReviewRemedyMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(action: try reader.required(.action), fingerprint: try reader.required(.fingerprint), reason: try reader.optional(.reason))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ReviewRemedyMember>()
    fields.put(.action, action)
    fields.put(.fingerprint, fingerprint)
    fields.put(.reason, reason)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

/// One per (review, finding), unique as at review.ts:89; a clear stores null, so whichever of a set and a clear is later stands on every device.
public struct ReviewRemedyRecord: KeyedRecord {
  public static let kind = NovelForgeKind.reviewRemedy

  public let key: NovelForgeKey
  public let review: UUID
  public let finding: String
  public let remedy: ReviewRemedy?

  public init(novel: UUID, review: UUID, finding: String, remedy: ReviewRemedy?) {
    let finding = finding.precomposedStringWithCanonicalMapping
    key = .reviewRemedyKey(novel: novel, review: review, finding: finding)
    self.review = review
    self.finding = finding
    self.remedy = remedy
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<ReviewRemedyField>) throws(UnreadableReason) {
    guard case .reviewRemedy(let review, let finding) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(novel: key.novel, review: review, finding: finding, remedy: try reader.optional(.remedy))
  }

  public var fields: RecordFields<ReviewRemedyField> {
    var fields = RecordFields<ReviewRemedyField>()
    fields.put(.remedy, remedy)
    return fields
  }

  public static func edit(_ ref: EntityRef, _ edit: RecordFields<ReviewRemedyField>, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is written only by set and clear")
  }

  public static func isPending(_ state: EntityState) -> Bool {
    guard case .record(let record) = state else { return false }
    return record[field: CommonField.naturalKey.rawValue] == nil
  }
}

extension ReviewRemedyRecord {
  public static func ref(novel: UUID, review: UUID, finding: String) -> EntityRef { NovelForgeKey.reviewRemedy(novel: novel, review: review, finding: finding) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, review: UUID, finding: String, in transaction: borrowing Transaction) throws(StoreError)
    -> RecordReading<ReviewRemedyRecord>
  {
    try read(ref(novel: novel, review: review, finding: finding), in: transaction)
  }

  public static func set(novel: UUID, review: UUID, finding: String, _ remedy: ReviewRemedy, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try ReviewRemedyRecord(novel: novel, review: review, finding: finding, remedy: remedy).create(in: &transaction)
  }

  public static func clear(novel: UUID, review: UUID, finding: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try ReviewRemedyRecord(novel: novel, review: review, finding: finding, remedy: nil).create(in: &transaction)
  }
}
