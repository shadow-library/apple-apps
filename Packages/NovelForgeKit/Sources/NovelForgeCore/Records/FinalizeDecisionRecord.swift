import Foundation
import ShadowCore
import ShadowStore

extension FinalizeDecisionField: FieldName {}
extension FinalizeDecisionMember: FieldName {}

/// The author's answer to one item, apps/novel-forge-server/src/database/schemas/finalize-review.ts:101-107: `proposalDigest` names the proposed change it answered,
/// `edit` keeps the shape `ProposedChange` reads, and `auto` marks a keep the pipeline made on the author's standing choice.
public struct StoredFinalizeAnswer: Sendable, Equatable {
  public var decision: StoredEnum<FinalizeDecision>
  public var proposalDigest: String
  public var edit: [String: JSONValue]?
  public var reason: String?
  public var auto: Bool
  public private(set) var unrecognised: [String: JSONValue]

  public init(decision: StoredEnum<FinalizeDecision>, proposalDigest: String, edit: [String: JSONValue]? = nil, reason: String? = nil, auto: Bool = false) {
    self.decision = decision
    self.proposalDigest = proposalDigest
    self.edit = edit
    self.reason = reason
    self.auto = auto
    unrecognised = [:]
  }
}

extension StoredFinalizeAnswer: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<FinalizeDecisionMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        decision: try reader.required(.decision), proposalDigest: try reader.required(.proposalDigest), edit: try reader.optional(.edit), reason: try reader.optional(.reason),
        auto: try reader.required(.auto))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<FinalizeDecisionMember>()
    fields.put(.decision, decision)
    fields.put(.proposalDigest, proposalDigest)
    fields.put(.edit, edit)
    fields.put(.reason, reason)
    fields.put(.auto, auto)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

/// Keyed by (chapter, draft revision, item key), never by review, so an answer stands through a re-read of the revision; the answer is one register, so the
/// later answer stands whole on every device.
public struct FinalizeDecisionRecord: KeyedRecord {
  public static let kind = NovelForgeKind.finalizeDecision

  public let key: NovelForgeKey
  public let chapter: Int
  public let draftRevision: String
  public let item: String
  public let answer: StoredFinalizeAnswer

  public init(novel: UUID, chapter: Int, draftRevision: String, item: String, answer: StoredFinalizeAnswer) throws(NovelForgeKeyError) {
    key = try .finalizeDecisionKey(novel: novel, chapter: chapter, draftRevision: draftRevision, item: item)
    guard case .finalizeDecision(_, let draftRevision, let item) = key.components else { throw .keyMismatch(key.ref) }
    self.chapter = chapter
    self.draftRevision = draftRevision
    self.item = item
    self.answer = answer
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<FinalizeDecisionField>) throws(UnreadableReason) {
    guard case .finalizeDecision(let chapter, let draftRevision, let item) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.key = key
    self.chapter = chapter
    self.draftRevision = draftRevision
    self.item = item
    answer = try reader.required(.decision)
  }

  public var fields: RecordFields<FinalizeDecisionField> {
    var fields = RecordFields<FinalizeDecisionField>()
    fields.put(.decision, answer)
    return fields
  }

  public static func edit(_ ref: EntityRef, _ edit: RecordFields<FinalizeDecisionField>, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is written whole by create")
  }

  public static func isPending(_ state: EntityState) -> Bool {
    guard case .record(let record) = state else { return false }
    return record[field: CommonField.naturalKey.rawValue] == nil
  }
}

extension FinalizeDecisionRecord {
  public static func ref(novel: UUID, chapter: Int, draftRevision: String, item: String) throws(NovelForgeKeyError) -> EntityRef {
    try NovelForgeKey.finalizeDecision(novel: novel, chapter: chapter, draftRevision: draftRevision, item: item)
  }

  /// Every revision's answers for the chapter; an unreadable answer counts when its key names this chapter.
  public static func listing<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(StoreError)
    -> RecordListing<FinalizeDecisionRecord>
  {
    let states = try transaction.states(ofKind: kind.entityKind, scope: .vault).filter { ref, state in
      guard let key = try? NovelForgeKey(reading: state, of: ref) else { return true }
      return key.components.chapters == [chapter]
    }
    return collecting(states, owner: novel)
  }
}
