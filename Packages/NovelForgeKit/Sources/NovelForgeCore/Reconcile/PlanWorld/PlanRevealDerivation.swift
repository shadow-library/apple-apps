import Foundation
import GRDB
import ShadowStore
import ShadowText

public enum PlanRevealStatus: String, Codable, CaseIterable, Sendable {
  case holds
  case violated
  /// The chapter is at or before the latest final chapter, so its plan is history and is not judged.
  case settled
  case unreadable
}

public struct PlanRevealViolation: Codable, Hashable, Sendable {
  public let fact: String
  public let missing: [String]

  // Byte-exact, so an unlock key respelled in a canonically equivalent form still replaces the stored row.
  public static func == (left: PlanRevealViolation, right: PlanRevealViolation) -> Bool {
    JSString(left.fact) == JSString(right.fact) && left.missing.map { JSString($0) } == right.missing.map { JSString($0) }
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(JSString(fact))
    hasher.combine(missing.map { JSString($0) })
  }
}

public struct PlanRevealEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_plan_reveal"

  public let novel: UUID
  public let chapter: Int
  public let status: PlanRevealStatus
  public let violations: [PlanRevealViolation]
  /// The ending that stands when this chapter is marked as an ending too; nil otherwise.
  public let rivalEnding: Int?

  enum CodingKeys: String, CodingKey {
    case novel
    case chapter
    case status
    case violations
    case rivalEnding = "rival_ending"
  }

  /// The reference's stale reason after its prefix (apps/novel-forge-server/src/common/plan-state.ts:94).
  public var reason: String? {
    violations.isEmpty ? nil : renderRevealRuleViolations(violations.map { RevealRuleViolation(factKey: $0.fact, missing: $0.missing) })
  }
}

// apps/novel-forge-server/src/common/plan-state.ts:91 (reconcilePlanState): one row per plan that is not removed; only a plan after the latest final chapter is judged.
// The reference refuses a second ending when a plan is written (plan-state.ts:40); two devices can still both mark one, so each other ending is flagged here.
public struct PlanRevealDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_plan_reveal (
      novel BLOB NOT NULL, chapter INTEGER NOT NULL, status TEXT NOT NULL, violations TEXT NOT NULL, rival_ending INTEGER, PRIMARY KEY (novel, chapter)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [.outputs(of: PlanWorldDerivation.self) { [$0.novel] }]
  }

  public static func key(of output: PlanRevealEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<PlanRevealEntry> {
    PlanRevealEntry.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(PlanWorldEntry.all()).map(\.novel))
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [PlanRevealEntry] {
    guard let world = try NovelPlanWorld.stored(for: novel, in: context) else { return [] }
    let latestEnding = world.latestEnding
    let contextAt = plannedUnlockContexts(world.planWorld, conditioned: true)
    let chapters = Dictionary(world.chapters.map { ($0.chapter, $0) }) { first, _ in first }
    let unreadable = Set(world.unreadablePlans)
    let judge = world.revealJudge
    return world.plans.map { chapter in
      let found = chapters[chapter]
      let rival = found?.ending == true && chapter != latestEnding ? latestEnding : nil
      let entry = { (status: PlanRevealStatus, violations: [PlanRevealViolation]) in
        PlanRevealEntry(novel: novel, chapter: chapter, status: status, violations: violations, rivalEnding: rival)
      }
      guard chapter > world.frontier else { return entry(.settled, []) }
      guard !unreadable.contains(chapter), let plan = found?.plan else { return entry(.unreadable, []) }
      let violations = judge(plan.row, contextAt(chapter))
      return entry(violations.isEmpty ? .holds : .violated, violations)
    }
  }
}
