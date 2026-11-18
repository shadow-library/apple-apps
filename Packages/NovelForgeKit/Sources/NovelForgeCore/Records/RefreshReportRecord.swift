import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

extension RefreshReportMember: FieldName {}

/// A chapter's canon refresh as apps/novel-forge-server/src/modules/audit/chapter-canon-refresh.service.ts:129-142 stores it: `findings` and `checked` keep the
/// shapes of database/schemas/jobs.ts:18-29 and :33-47, `copy` is the summary line renderReportSummary makes (:107; `checked` keeps its own `copy`), and
/// `proposal` is the staged bible_audit card.
public struct RefreshReportRecord: ChapterAppendedRecord {
  public static let kind = NovelForgeKind.refreshReport
  public static let novelMember = RefreshReportMember.novel
  public static let chapterMember = RefreshReportMember.chapter

  public let id: UUID
  public let novel: UUID
  public let chapter: Int
  public let canonDigest: String
  public let findings: [[String: JSONValue]]
  public let checked: [String: JSONValue]
  public let copy: String
  public let proposal: UUID?
  public let attempt: AttemptID?
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    id: UUID = UUID(), novel: UUID, chapter: Int, canonDigest: String, findings: [[String: JSONValue]], checked: [String: JSONValue], copy: String,
    proposal: UUID? = nil, attempt: AttemptID? = nil
  ) {
    self.id = id
    self.novel = novel
    self.chapter = chapter
    self.canonDigest = canonDigest
    self.findings = findings
    self.checked = checked
    self.copy = copy
    self.proposal = proposal
    self.attempt = attempt
    unrecognised = [:]
  }

  public init(id: UUID, reading reader: FieldReader<RefreshReportMember>) throws(UnreadableReason) {
    self.init(
      id: id, novel: try reader.required(.novel), chapter: try reader.required(.chapter), canonDigest: try reader.required(.canonDigest),
      findings: try reader.required(.findings), checked: try reader.required(.checked), copy: try reader.required(.copy), proposal: try reader.optional(.proposal),
      attempt: try reader.optional(.attempt))
    unrecognised = reader.unrecognised
  }

  public var members: RecordFields<RefreshReportMember> {
    var fields = RecordFields<RefreshReportMember>()
    fields.put(.novel, novel)
    fields.put(.chapter, chapter)
    fields.put(.canonDigest, canonDigest)
    fields.put(.findings, findings)
    fields.put(.checked, checked)
    fields.put(.copy, copy)
    fields.put(.proposal, proposal)
    fields.put(.attempt, attempt)
    return fields
  }
}
