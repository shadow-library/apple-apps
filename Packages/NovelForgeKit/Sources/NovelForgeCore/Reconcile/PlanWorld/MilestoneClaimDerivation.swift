import Foundation
import GRDB
import ShadowStore

public enum MilestoneClaimStatus: String, Codable, CaseIterable, Sendable {
  case holds
  case duplicate
  /// No milestone of the novel has the key: it never existed or was removed.
  case unknown
}

public struct MilestoneClaimEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_milestone_claim"

  public let novel: UUID
  public let milestone: String
  public let chapter: Int
  public let basis: ClaimBasis
  public let status: MilestoneClaimStatus
  /// The chapter whose claim holds; nil for an unknown milestone.
  public let holder: Int?
}

// The reference refuses a second claim when the plan is written (apps/novel-forge-server/src/common/reveal-rule.ts:125); two devices can still both claim, so the
// earliest claim holds, a final chapter's before any plan's, and every other claim is flagged on its chapter.
public struct MilestoneClaimDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_milestone_claim (
      novel BLOB NOT NULL, milestone TEXT NOT NULL, chapter INTEGER NOT NULL, basis TEXT NOT NULL, status TEXT NOT NULL, holder INTEGER,
      PRIMARY KEY (novel, milestone, chapter)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_milestone_claim_chapter ON nf_derived_milestone_claim (novel, chapter);
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [.outputs(of: PlanWorldDerivation.self) { [$0.novel] }]
  }

  public static func key(of output: MilestoneClaimEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<MilestoneClaimEntry> {
    MilestoneClaimEntry.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(PlanWorldEntry.all()).map(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [MilestoneClaimEntry] {
    guard let world = try NovelPlanWorld.stored(for: novel, in: context) else { return [] }
    let known = Set(world.milestones.map { JSString($0) })
    let tallies = world.claimTallies
    var entries = [MilestoneClaimEntry]()
    for chapter in world.chapters {
      for key in chapter.claims {
        let holder = known.contains(JSString(key)) ? tallies[JSString(key)]?.holder : nil
        let status: MilestoneClaimStatus =
          switch holder {
          case nil: .unknown
          case chapter.chapter?: .holds
          default: .duplicate
          }
        entries.append(MilestoneClaimEntry(novel: novel, milestone: key, chapter: chapter.chapter, basis: chapter.basis, status: status, holder: holder))
      }
    }
    return entries
  }
}
