import Foundation
import ShadowCore
import ShadowStore

extension ApprovalMember: FieldName {}

// apps/novel-forge-server/src/database/schemas/generation.ts:53 keeps one approved revision per draft; here every approval is an item and the one in force is derived
public struct ApprovalRecord: AppendedRecord {
  public static let kind = NovelForgeKind.approval
  public static let novelMember = ApprovalMember.novel

  public let id: UUID
  public let novel: UUID
  public let chapter: Int
  public let approvalKind: StoredEnum<ApprovalKind>
  public let draftRevision: String
  public let planRevision: String
  public let planTermsDigest: String?
  public let upstreamDigest: String?
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    id: UUID = UUID(), novel: UUID, chapter: Int, approvalKind: StoredEnum<ApprovalKind> = .known(.standard), draftRevision: String, planRevision: String,
    planTermsDigest: String? = nil, upstreamDigest: String? = nil
  ) {
    self.id = id
    self.novel = novel
    self.chapter = chapter
    self.approvalKind = approvalKind
    self.draftRevision = draftRevision
    self.planRevision = planRevision
    self.planTermsDigest = planTermsDigest
    self.upstreamDigest = upstreamDigest
    unrecognised = [:]
  }

  public init(id: UUID, reading reader: FieldReader<ApprovalMember>) throws(UnreadableReason) {
    self.init(
      id: id, novel: try reader.required(.novel), chapter: try reader.required(.chapter), approvalKind: try reader.required(.kind),
      draftRevision: try reader.required(.draftRevision), planRevision: try reader.required(.planRevision), planTermsDigest: try reader.optional(.planTermsDigest),
      upstreamDigest: try reader.optional(.upstreamDigest))
    unrecognised = reader.unrecognised
  }

  public var members: RecordFields<ApprovalMember> {
    var fields = RecordFields<ApprovalMember>()
    fields.put(.novel, novel)
    fields.put(.chapter, chapter)
    fields.put(.kind, approvalKind)
    fields.put(.draftRevision, draftRevision)
    fields.put(.planRevision, planRevision)
    fields.put(.planTermsDigest, planTermsDigest)
    fields.put(.upstreamDigest, upstreamDigest)
    return fields
  }
}

extension ApprovalRecord {
  public static func listing<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(StoreError)
    -> AppendedListing<ApprovalRecord>
  {
    collecting(try transaction.states(ofKind: kind.entityKind, scope: .vault), owner: novel) { reader in
      let stored: Int? = try? reader.required(.chapter)
      return stored.map { $0 == chapter } ?? true
    }
  }
}
