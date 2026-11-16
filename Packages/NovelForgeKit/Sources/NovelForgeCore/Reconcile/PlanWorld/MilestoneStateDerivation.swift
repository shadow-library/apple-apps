import Foundation
import GRDB
import ShadowStore

public struct MilestoneStateEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_milestone_state"

  public let novel: UUID
  public let milestone: String
  public let state: MilestoneState
  public let plannedChapter: Int?
  public let reachedChapter: Int?

  enum CodingKeys: String, CodingKey {
    case novel
    case milestone
    case state
    case plannedChapter = "planned_chapter"
    case reachedChapter = "reached_chapter"
  }

  init(novel: UUID, milestone: String, tally: ClaimTally) {
    self.novel = novel
    self.milestone = milestone
    state = tally.state
    plannedChapter = tally.holder
    reachedChapter = tally.reachedChapter
  }
}

// Until finalize review exists a milestone is reached only by a final chapter whose canon claims it, as finalizing without a review does
// (apps/novel-forge-server/src/modules/ai/graphs/chapter-finalization.graph.ts:177); a removed milestone has no state.
public struct MilestoneStateDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_milestone_state (
      novel BLOB NOT NULL, milestone TEXT NOT NULL, state TEXT NOT NULL, planned_chapter INTEGER, reached_chapter INTEGER, PRIMARY KEY (novel, milestone)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [.outputs(of: PlanWorldDerivation.self) { [$0.novel] }]
  }

  public static func key(of output: MilestoneStateEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<MilestoneStateEntry> {
    MilestoneStateEntry.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(PlanWorldEntry.all()).map(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [MilestoneStateEntry] {
    guard let world = try NovelPlanWorld.stored(for: novel, in: context) else { return [] }
    let tallies = world.claimTallies
    return world.milestones.jsUnique().map { key in MilestoneStateEntry(novel: novel, milestone: key, tally: tallies[JSString(key)] ?? ClaimTally()) }
  }
}
