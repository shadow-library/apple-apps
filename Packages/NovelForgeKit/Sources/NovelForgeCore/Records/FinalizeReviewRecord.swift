import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

extension FinalizeReviewMember: FieldName {}
extension FinalizeReviewItemMember: FieldName {}

/// apps/novel-forge-server/src/database/schemas/finalize-review.ts:84-113 without the answer; `proposed` keeps the shape `ProposedChange` reads
/// (modules/finalize-review/finalize-review-items.ts:14), and `autoDecision` is the keep buildReviewItems made on its own. The key is kept precomposed, as the
/// decision key that answers it is. An automatic keep lives only here, never as a decision record: a whole-value answer from a stale device would override a skip.
public struct StoredFinalizeItem: Sendable, Equatable {
  public var key: String
  public var position: Int
  public var category: StoredEnum<FinalizeCategory>
  public var triage: StoredEnum<FinalizeTriage>
  public var basis: StoredEnum<FinalizeBasis>
  public var subject: String
  public var claim: String
  public var evidence: String?
  public var proposed: [String: JSONValue]
  public var flag: StoredEnum<FinalizeFlag>?
  public var dependents: [String]?
  public var autoDecision: StoredEnum<FinalizeDecision>?
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    key: String, position: Int, category: StoredEnum<FinalizeCategory>, triage: StoredEnum<FinalizeTriage>, basis: StoredEnum<FinalizeBasis>, subject: String,
    claim: String, evidence: String? = nil, proposed: [String: JSONValue], flag: StoredEnum<FinalizeFlag>? = nil, dependents: [String]? = nil,
    autoDecision: StoredEnum<FinalizeDecision>? = nil
  ) {
    self.key = key.precomposedStringWithCanonicalMapping
    self.position = position
    self.category = category
    self.triage = triage
    self.basis = basis
    self.subject = subject
    self.claim = claim
    self.evidence = evidence
    self.proposed = proposed
    self.flag = flag
    self.dependents = dependents
    self.autoDecision = autoDecision
    unrecognised = [:]
  }
}

extension StoredFinalizeItem: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<FinalizeReviewItemMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        key: try reader.required(.key), position: try reader.required(.position), category: try reader.required(.category), triage: try reader.required(.triage),
        basis: try reader.required(.basis), subject: try reader.required(.subject), claim: try reader.required(.claim), evidence: try reader.optional(.evidence),
        proposed: try reader.required(.proposed), flag: try reader.optional(.flag), dependents: try reader.optional(.dependents),
        autoDecision: try reader.optional(.autoDecision))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<FinalizeReviewItemMember>()
    fields.put(.key, key)
    fields.put(.position, position)
    fields.put(.category, category)
    fields.put(.triage, triage)
    fields.put(.basis, basis)
    fields.put(.subject, subject)
    fields.put(.claim, claim)
    fields.put(.evidence, evidence)
    fields.put(.proposed, proposed)
    fields.put(.flag, flag)
    fields.put(.dependents, dependents)
    fields.put(.autoDecision, autoDecision)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

/// apps/novel-forge-server/src/database/schemas/finalize-review.ts:50-82, appended only once an attempt has read it out, so it is always ready; its id is its
/// attempt's, which makes one per attempt. The author's answers are finalize decision records, keyed by revision and item key so they outlive a re-read.
/// Appending an id that exists throws, so a resumed attempt appends in its checkpoint transaction or reads `read(id:)` first.
public struct FinalizeReviewRecord: ChapterAppendedRecord {
  public static let kind = NovelForgeKind.finalizeReview
  public static let novelMember = FinalizeReviewMember.novel
  public static let chapterMember = FinalizeReviewMember.chapter

  public let id: UUID
  public let novel: UUID
  public let chapter: Int
  public let draftRevision: String
  public let sourceHash: String
  public let planHash: String?
  public let isolated: Bool
  public let job: EntityKey
  public let attempt: AttemptID
  public let items: [StoredFinalizeItem]
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    attempt: AttemptID, job: EntityKey, novel: UUID, chapter: Int, draftRevision: String, sourceHash: String, planHash: String?, isolated: Bool,
    items: [StoredFinalizeItem]
  ) throws(ReviewRecordError) {
    if let repeated = firstRepeated(items.map(\.key)) { throw .duplicateItem(repeated) }
    self.init(
      unchecked: attempt, job: job, novel: novel, chapter: chapter, draftRevision: draftRevision, sourceHash: sourceHash, planHash: planHash, isolated: isolated,
      items: items)
  }

  public init(id: UUID, reading reader: FieldReader<FinalizeReviewMember>) throws(UnreadableReason) {
    let attempt: AttemptID = try reader.required(.attempt)
    guard attempt.uuid == id else { throw .invalid(field: FinalizeReviewMember.attempt.rawValue) }
    let items: [StoredFinalizeItem] = try reader.required(.items)
    guard firstRepeated(items.map(\.key)) == nil else { throw .invalid(field: FinalizeReviewMember.items.rawValue) }
    self.init(
      unchecked: attempt, job: try reader.required(.job), novel: try reader.required(.novel), chapter: try reader.required(.chapter),
      draftRevision: try reader.required(.draftRevision), sourceHash: try reader.required(.sourceHash), planHash: try reader.optional(.planHash),
      isolated: try reader.required(.isolated), items: items)
    unrecognised = reader.unrecognised
  }

  private init(
    unchecked attempt: AttemptID, job: EntityKey, novel: UUID, chapter: Int, draftRevision: String, sourceHash: String, planHash: String?, isolated: Bool,
    items: [StoredFinalizeItem]
  ) {
    id = attempt.uuid
    self.novel = novel
    self.chapter = chapter
    self.draftRevision = draftRevision
    self.sourceHash = sourceHash
    self.planHash = planHash
    self.isolated = isolated
    self.job = job
    self.attempt = attempt
    self.items = items
    unrecognised = [:]
  }

  public var members: RecordFields<FinalizeReviewMember> {
    var fields = RecordFields<FinalizeReviewMember>()
    fields.put(.novel, novel)
    fields.put(.chapter, chapter)
    fields.put(.draftRevision, draftRevision)
    fields.put(.sourceHash, sourceHash)
    fields.put(.planHash, planHash)
    fields.put(.isolated, isolated)
    fields.put(.job, job)
    fields.put(.attempt, attempt)
    fields.put(.items, items)
    return fields
  }
}

extension FinalizeReviewRecord {
  public static func ref(attempt: AttemptID) -> EntityRef { ref(attempt.uuid) }
}
