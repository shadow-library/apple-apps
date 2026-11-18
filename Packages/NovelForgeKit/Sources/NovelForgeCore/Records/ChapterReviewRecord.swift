import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

extension ChapterReviewMember: FieldName {}
extension ReviewFindingMember: FieldName {}

public enum ReviewRecordError: ShadowError, Equatable {
  case duplicateFinding(String)
  case duplicateItem(String)

  public var code: String {
    switch self {
    case .duplicateFinding: "review_record.duplicate_finding"
    case .duplicateItem: "review_record.duplicate_item"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .duplicateFinding(let id): "Two findings of one review share the id \"\(id)\"."
    case .duplicateItem(let key): "Two items of one finalize review share the key \"\(key)\"."
    }
  }
}

func firstRepeated(_ names: [String]) -> String? {
  var seen = Set<String>()
  return names.first { !seen.insert($0).inserted }
}

// apps/novel-forge-server/src/database/schemas/review.ts:11-21
public struct ReviewFinding: Sendable, Equatable {
  public var id: String
  public var severity: StoredEnum<ReviewFindingSeverity>
  public var category: StoredEnum<ReviewFindingCategory>
  public var text: String
  public var evidence: String?
  public var fingerprint: String
  public private(set) var unrecognised: [String: JSONValue]

  /// The id is kept precomposed, as the remedy key that addresses it is.
  public init(id: String, severity: StoredEnum<ReviewFindingSeverity>, category: StoredEnum<ReviewFindingCategory>, text: String, evidence: String? = nil, fingerprint: String) {
    self.id = id.precomposedStringWithCanonicalMapping
    self.severity = severity
    self.category = category
    self.text = text
    self.evidence = evidence
    self.fingerprint = fingerprint
    unrecognised = [:]
  }
}

extension ReviewFinding: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<ReviewFindingMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        id: try reader.required(.id), severity: try reader.required(.severity), category: try reader.required(.category), text: try reader.required(.text),
        evidence: try reader.optional(.evidence), fingerprint: try reader.required(.fingerprint))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ReviewFindingMember>()
    fields.put(.id, id)
    fields.put(.severity, severity)
    fields.put(.category, category)
    fields.put(.text, text)
    fields.put(.evidence, evidence)
    fields.put(.fingerprint, fingerprint)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

/// apps/novel-forge-server/src/database/schemas/review.ts:40-73, one item per review run; a remedy of one of its findings is a review remedy record.
public struct ChapterReviewRecord: ChapterAppendedRecord {
  public static let kind = NovelForgeKind.chapterReview
  public static let novelMember = ChapterReviewMember.novel
  public static let chapterMember = ChapterReviewMember.chapter

  public let id: UUID
  public let novel: UUID
  public let chapter: Int
  public let reviewKind: StoredEnum<ChapterReviewKind>
  /// Nil when the chapter had no draft revision to review (review.ts:48).
  public let draftRevision: String?
  public let bodyHash: String
  public let disposition: StoredEnum<ChapterReviewDisposition>
  public let verdict: String?
  public let findings: [ReviewFinding]
  public let isolated: Bool
  public let note: String?
  public let checked: [String]
  public let generationPass: Bool
  public let job: EntityKey?
  public let attempt: AttemptID?
  public let calls: [UUID]?
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    id: UUID = UUID(), novel: UUID, chapter: Int, reviewKind: StoredEnum<ChapterReviewKind>, draftRevision: String?, bodyHash: String,
    disposition: StoredEnum<ChapterReviewDisposition>, verdict: String? = nil, findings: [ReviewFinding] = [], isolated: Bool = false, note: String? = nil,
    checked: [String] = [], generationPass: Bool = false, job: EntityKey? = nil, attempt: AttemptID? = nil, calls: [UUID]? = nil
  ) throws(ReviewRecordError) {
    if let repeated = firstRepeated(findings.map(\.id)) { throw .duplicateFinding(repeated) }
    self.init(
      unchecked: id, novel: novel, chapter: chapter, reviewKind: reviewKind, draftRevision: draftRevision, bodyHash: bodyHash, disposition: disposition, verdict: verdict,
      findings: findings, isolated: isolated, note: note, checked: checked, generationPass: generationPass, job: job, attempt: attempt, calls: calls)
  }

  public init(id: UUID, reading reader: FieldReader<ChapterReviewMember>) throws(UnreadableReason) {
    let findings: [ReviewFinding] = try reader.required(.findings)
    guard firstRepeated(findings.map(\.id)) == nil else { throw .invalid(field: ChapterReviewMember.findings.rawValue) }
    self.init(
      unchecked: id, novel: try reader.required(.novel), chapter: try reader.required(.chapter), reviewKind: try reader.required(.kind),
      draftRevision: try reader.optional(.draftRevision), bodyHash: try reader.required(.bodyHash), disposition: try reader.required(.disposition),
      verdict: try reader.optional(.verdict), findings: findings, isolated: try reader.required(.isolated), note: try reader.optional(.note),
      checked: try reader.required(.checked), generationPass: try reader.required(.generationPass), job: try reader.optional(.job), attempt: try reader.optional(.attempt),
      calls: try reader.optional(.calls))
    unrecognised = reader.unrecognised
  }

  private init(
    unchecked id: UUID, novel: UUID, chapter: Int, reviewKind: StoredEnum<ChapterReviewKind>, draftRevision: String?, bodyHash: String,
    disposition: StoredEnum<ChapterReviewDisposition>, verdict: String?, findings: [ReviewFinding], isolated: Bool, note: String?, checked: [String], generationPass: Bool,
    job: EntityKey?, attempt: AttemptID?, calls: [UUID]?
  ) {
    self.id = id
    self.novel = novel
    self.chapter = chapter
    self.reviewKind = reviewKind
    self.draftRevision = draftRevision
    self.bodyHash = bodyHash
    self.disposition = disposition
    self.verdict = verdict
    self.findings = findings
    self.isolated = isolated
    self.note = note
    self.checked = checked
    self.generationPass = generationPass
    self.job = job
    self.attempt = attempt
    self.calls = calls
    unrecognised = [:]
  }

  public var members: RecordFields<ChapterReviewMember> {
    var fields = RecordFields<ChapterReviewMember>()
    fields.put(.novel, novel)
    fields.put(.chapter, chapter)
    fields.put(.kind, reviewKind)
    fields.put(.draftRevision, draftRevision)
    fields.put(.bodyHash, bodyHash)
    fields.put(.disposition, disposition)
    fields.put(.verdict, verdict)
    fields.put(.findings, findings)
    fields.put(.isolated, isolated)
    fields.put(.note, note)
    fields.put(.checked, checked)
    fields.put(.generationPass, generationPass)
    fields.put(.job, job)
    fields.put(.attempt, attempt)
    fields.put(.calls, calls)
    return fields
  }
}
