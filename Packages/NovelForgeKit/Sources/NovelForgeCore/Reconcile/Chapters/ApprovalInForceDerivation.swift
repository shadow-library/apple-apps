import Foundation
import GRDB
import ShadowCore
import ShadowStore

public struct ApprovalInForce: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_approval_in_force"

  public let novel: UUID
  public let chapter: Int
  public let approval: UUID
  public let kind: ApprovalKind
  public let draftRevision: String
  public let clock: HLCTimestamp

  init(novel: UUID, chapter: Int, approval: UUID, kind: ApprovalKind, draftRevision: String, clock: HLCTimestamp) {
    self.novel = novel
    self.chapter = chapter
    self.approval = approval
    self.kind = kind
    self.draftRevision = draftRevision
    self.clock = clock
  }

  public init(row: Row) throws {
    guard let approval = ApprovalColumn.decode(try row.decode(String.self, forColumn: "approval")),
      let kind = ApprovalKind(rawValue: try row.decode(String.self, forColumn: "kind")), let clock = HLCTimestamp(try row.decode(String.self, forColumn: "clock"))
    else { throw StoreError.corruptStore("an approval in force holds an invalid id, kind or clock") }
    self.init(
      novel: try row.decode(UUID.self, forColumn: "novel"), chapter: try row.decode(Int.self, forColumn: "chapter"), approval: approval, kind: kind,
      draftRevision: try row.decode(String.self, forColumn: "draft"), clock: clock)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["novel"] = novel
    container["chapter"] = chapter
    container["approval"] = ApprovalColumn.encode(approval)
    container["kind"] = kind.rawValue
    container["draft"] = draftRevision
    container["clock"] = clock.description
  }
}

// ChapterFingerprint rule 6, kept apart from the lifecycle so what reads approvals (provisional knowledge) changes only when one starts or stops holding.
public struct ApprovalInForceDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_approval_in_force (
      novel BLOB NOT NULL, chapter INTEGER NOT NULL, approval TEXT NOT NULL, kind TEXT NOT NULL, draft TEXT NOT NULL, clock TEXT NOT NULL,
      PRIMARY KEY (novel, chapter)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [.outputs(of: ChapterLifecycleDerivation.self) { [$0.novel] }, .outputs(of: ChapterApprovalDerivation.self) { [$0.novel] }]
  }

  public static func key(of output: ApprovalInForce) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<ApprovalInForce> {
    ApprovalInForce.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(ChapterLifecycleEntry.all()).map(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [ApprovalInForce] {
    var held = [ApprovalInForce]()
    for entry in try context.fetchAll(ChapterLifecycleDerivation.request(for: novel)) {
      guard let approval = entry.approval, let kind = entry.approvalKind, let draft = entry.draft,
        let item = try context.fetchAll(ChapterApprovalDerivation.request(for: ApprovalRecord.ref(approval))).first
      else { continue }
      held.append(ApprovalInForce(novel: novel, chapter: entry.chapter, approval: approval, kind: kind, draftRevision: draft, clock: item.clock))
    }
    return held
  }
}
