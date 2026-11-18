import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

/// The phase 5 done-when check: three replicas, random domain operations (refusals included) and any delivery order. Each block of `settleEvery` steps opens
/// with a partition, `partition` steps of writes and no deliveries, in which a second device often does the same or something in the same area, so devices diverge on the
/// same records; now and then the replica a step touched is compared with a rebuild. At
/// the end of each block all replicas settle and hold the same tables; replica 0 at every settle point, and every replica at the end, is a rebuild with no
/// fault, keeps every rule of the invariant table and loads every read model. A failure names its replay seed; `NOVELFORGE_DOMAIN_REPLAY=<seed>` runs that one case.
struct DomainProperty: Sendable {
  static let replaySeed = ProcessInfo.processInfo.environment["NOVELFORGE_DOMAIN_REPLAY"].flatMap(parseSeed)

  static let areas = [DomainOperations.library, DomainOperations.story, DomainOperations.bible, DomainOperations.notebook, DomainChapterOperations.all]
  /// The chapter operations with the generate jobs, judge reviews and remedies the lifecycle reads.
  static let lifecycleAreas = [DomainChapterOperations.all, DomainReviewOperations.all]

  var areas = Self.areas

  var iterations = 6
  var steps = 80
  var settleEvery = 20
  var partition = 8
  var checkRate = 0.1
  let tally = DomainTally()

  var operations: [DomainOperation] { Array(areas.joined()) }

  func check(order: CausalReplicaOrder, seed: UInt64) async throws {
    let reconciler = try Projection.reconciler()
    do {
      if let replaySeed = Self.replaySeed {
        try await replay(seed: replaySeed) { generator in try await run(order: order, reconciler: reconciler, &generator) }
      } else {
        try await forAllConcurrently(iterations: ProjectionProperty.gatedIterations(iterations), seed: seed) { generator in
          try await run(order: order, reconciler: reconciler, &generator)
        }
      }
    } catch {
      throw DomainRunFailure.inOrder("\(order)", error.description)
    }
  }

  private func run(order: CausalReplicaOrder, reconciler: NovelForgeReconciler, _ generator: inout SeededGenerator) async throws {
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, order: order, reconciler: { _ in reconciler }, seed: generator.next()))
    let universe = DomainUniverse(&generator)
    try await universe.setUp(on: replicas)
    try await universe.prologue(on: replicas)
    for step in 1...steps {
      var touched: Int?
      let partitioned = (step - 1) % settleEvery < partition
      if partitioned || generator.chance(0.5) {
        let (operation, index) = (DomainOperation.pick(from: operations, &generator), generator.int(in: 0...2))
        try await perform(operation, on: index, in: replicas, universe, &generator)
        touched = index
        if partitioned, generator.chance(0.6) {
          let area = areas.first { $0.contains { $0.name == operation.name } } ?? operations
          let partner = generator.chance(0.5) ? operation : DomainOperation.pick(from: area, &generator)
          try await perform(partner, on: (index + generator.int(in: 1...2)) % 3, in: replicas, universe, &generator)
        }
      } else {
        let delivered = await replicas.deliveries().count
        if try await replicas.step(using: &generator), await replicas.deliveries().count > delivered { touched = await replicas.deliveries().last?.reader }
      }
      if let touched, generator.chance(checkRate) { try await Self.expectRebuilt(reconciler, replica: touched, in: replicas) }
      guard step % settleEvery == 0 || step == steps else { continue }
      try await replicas.settle()
      try await Self.expectSettled(reconciler, novels: universe.novels, in: replicas, everyReplica: step == steps, tally: tally)
    }
  }

  private func perform(
    _ operation: DomainOperation, on index: Int, in replicas: CausalReplicas, _ universe: DomainUniverse, _ generator: inout SeededGenerator
  ) async throws {
    await replicas.advanceClock(of: index, by: generator.chance(0.3) ? .seconds(700) : .milliseconds(generator.int(in: 0...50)))
    try await replicas.perform(operation, operation.make(&generator, universe), on: index, tally: tally)
  }

  static func expectRebuilt(_ reconciler: NovelForgeReconciler, replica index: Int, in replicas: CausalReplicas) async throws {
    let comparison = try await Projection.compare(reconciler, in: await replicas.store(index))
    let differing = comparison.incremental.keys.filter { comparison.incremental[$0] != comparison.rebuilt[$0] }.sorted()
    guard differing.isEmpty else { throw DomainRunFailure.notARebuild(replica: index, tables: differing) }
    let faults = comparison.incremental[reconciler.faultTable] ?? []
    guard faults.isEmpty else { throw DomainRunFailure.faults(replica: index, faults) }
  }

  /// Every replica holds replica 0's tables; replica 0, or with `everyReplica` each of them, is a rebuild with no fault and keeps every invariant.
  static func expectSettled(
    _ reconciler: NovelForgeReconciler, novels: [UUID], in replicas: CausalReplicas, everyReplica: Bool = true, tally: DomainTally? = nil
  ) async throws {
    guard await replicas.isSettled() else { throw DomainRunFailure.unsettled }
    let first = try await Projection.derived(reconciler, in: await replicas.store(0))
    for index in 0..<replicas.count {
      let store = await replicas.store(index)
      let tables = try await Projection.derived(reconciler, in: store)
      let differing = Set(first.keys).union(tables.keys).filter { first[$0] != tables[$0] }.sorted()
      guard differing.isEmpty else { throw DomainRunFailure.diverged(replica: index, tables: differing) }
      guard everyReplica || index == 0 else { continue }
      try await expectRebuilt(reconciler, replica: index, in: replicas)
      let violations = try await store.read { transaction in try DomainInvariants.check(novels, in: transaction) }
      guard violations.isEmpty else { throw DomainRunFailure.invariants(replica: index, violations) }
    }
    if let tally { try await DomainReach.record(in: await replicas.store(0), into: tally) }
  }

  private static func parseSeed(_ text: String) -> UInt64? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    return trimmed.hasPrefix("0x") ? UInt64(trimmed.dropFirst(2), radix: 16) : UInt64(trimmed)
  }
}

/// The states the default runs of both delivery orders reach between them, each at several settle points, so the property is known to reach what its
/// invariants are about.
enum DomainReach {
  static let features: KeyValuePairs = [
    "a final chapter": "SELECT 1 FROM nf_derived_final_chapter",
    "two final chapters": "SELECT 1 FROM nf_derived_final_chapter WHERE chapter >= 2",
    "an approval in force": "SELECT 1 FROM nf_derived_approval_in_force",
    "committed knowledge": "SELECT 1 FROM nf_derived_character_knowledge WHERE source = 'brief' AND status = 'committed'",
    "provisional knowledge": "SELECT 1 FROM nf_derived_character_knowledge WHERE status = 'provisional'",
    "a superseded entry": "SELECT 1 FROM nf_derived_notebook_entry WHERE status = 'superseded'",
    "a withdrawal over a successor": "SELECT 1 FROM nf_derived_notebook_entry WHERE status = 'withdrawn' AND successor IS NOT NULL",
    "a met volume goal": "SELECT 1 FROM nf_derived_volume_state WHERE state = 'goal_met'",
    "an inverted volume order": """
    SELECT 1 FROM nf_derived_volume_state AS a JOIN nf_derived_volume_state AS b ON a.novel = b.novel AND a.ordinal < b.ordinal AND a.volume > b.volume
    """,
    "a duplicate milestone claim": "SELECT 1 FROM nf_derived_milestone_claim WHERE status = 'duplicate'",
    "a violated plan": "SELECT 1 FROM nf_derived_plan_reveal WHERE status = 'violated'",
    "a rival ending": "SELECT 1 FROM nf_derived_plan_reveal WHERE rival_ending IS NOT NULL",
    "a draft stale on an ancestor's draft": "SELECT 1 FROM nf_derived_chapter_lifecycle WHERE stale = 'draft'",
    "a draft stale on an ancestor's knowledge": "SELECT 1 FROM nf_derived_chapter_lifecycle WHERE stale = 'knowledge'",
    "a draft stale on a replaced canon": "SELECT 1 FROM nf_derived_chapter_lifecycle WHERE stale = 'canon'",
    "a draft stale on its plan's reveals": "SELECT 1 FROM nf_derived_chapter_lifecycle WHERE stale = 'reveal'",
    "accepted differences": "SELECT 1 FROM nf_derived_chapter_lifecycle WHERE differences IS NOT NULL AND stale IS NULL AND NOT final",
  ]

  /// What the lifecycle property must reach, at `DomainPropertyTests.minimumReach` settle points.
  static let lifecycle: KeyValuePairs = [
    "a generating chapter": "SELECT 1 FROM nf_derived_chapter_lifecycle WHERE review = 'generating'",
    "a draft held as a contradiction": "SELECT 1 FROM nf_derived_chapter_lifecycle WHERE review = 'contradiction'",
  ]

  /// Reached at fewer settle points than the gate asks within the time budget, so each is pinned by the scenario named instead. A draft stale as `unrecorded`
  /// is not listed: every revision a domain operation writes records its upstream, so Chapters/LifecycleScenarioTests covers it with stored shapes.
  static let scenarioOnly: KeyValuePairs = [
    "provisional knowledge": "shouldHoldTheLaterOfTwoApprovalsOfOneHeadAndBindItWhenTheChapterIsFinalized (the knowledge oracle requires the row)",
    "a duplicate milestone claim": "shouldHoldTheEarliestClaimAndFlagTheOtherWhenTwoDevicesClaimOneMilestone",
    "a violated plan": "shouldMarkAPlanAndItsDraftWhenAnotherDeviceMovesTheRevealOfAFactItTeachesLater",
    "a draft stale on its plan's reveals": "shouldMarkAPlanAndItsDraftWhenAnotherDeviceMovesTheRevealOfAFactItTeachesLater",
    "accepted differences": "shouldRevokeALaterChaptersApprovalWhenAnotherDeviceRewritesTheChapterItRestsOn",
  ]

  static func record(in store: VaultStore, into tally: DomainTally) async throws {
    let reached = try await store.read { transaction in
      try (Array(features) + Array(lifecycle)).filter { _, sql in try Bool.fetchOne(transaction.database, sql: "SELECT EXISTS (\(sql))") ?? false }.map(\.key)
    }
    for feature in reached { tally.record("reached \(feature)") }
  }
}
