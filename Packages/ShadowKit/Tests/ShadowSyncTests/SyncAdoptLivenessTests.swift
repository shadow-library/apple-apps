import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

/// Runs adoption on `harness` until a call finds nothing to do, checking after every call that a fresh reader with a perfect view converges.
private func finishConverging(_ harness: SyncHarness, in scenario: SyncAdoptScenario, _ name: String) async throws -> [SyncAdoptionOutcome] {
  var outcomes: [SyncAdoptionOutcome] = []
  for call in 0..<8 {
    let outcome = try await harness.engine.adopt()
    outcomes.append(outcome)
    try await scenario.expectConverges(try await scenario.freshReader("\(name)-\(call)"), "\(name) call \(call)")
    if outcome == .nothingToAdopt { return outcomes }
  }
  throw SyncFixtureFailure("\(name) did not come to rest: \(outcomes)")
}

@Suite("SyncEngine adoption that must finish")
struct SyncAdoptLivenessTests {
  @Test("should finish a late segment after the adopter is re-minted outside the engine, starting its head from the facts its own writes hold")
  func shouldFinishAfterRemintOutsideEngine() async throws {
    var settings = adoptSettings
    settings.compactionAge = SyncDays.duration(60)
    let scenario = try await SyncAdoptScenario.make(settings: settings)
    let retired = scenario.retired
    let late = once {
      try await retired.writeNotes(1, prefix: "late-", title: SyncAdoptScenario.title("late"))
      _ = try await retired.uploaded()
    }
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.published) { try await late() } })
    #expect(try await adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    try await scenario.expectConverges(try await scenario.freshReader("first"), "first")
    let old = scenario.adopterID
    let elsewhere = ReplicaLifecycle(
      store: scenario.adopterStore, vault: SyncFixture.vault, marker: ReplicaFixture.marker(scenario.world.keychain, "adopter"), device: ReplicaFixture.phone,
      wallClock: { scenario.world.clock.now })
    _ = try await elsewhere.remint(reason: .clockCorrected)
    scenario.world.advance(days: 31)
    try await scenario.expectConverges(try await scenario.freshReader("reminted"), "reminted")

    let outcomes = try await finishConverging(adopter, in: scenario, "after")

    #expect(
      outcomes.flatMap { outcome -> [ReplicaID] in
        guard case .progressed(let adopted, _) = outcome else { return [] }
        return adopted
      }.sorted() == [old, scenario.retiredID].sorted())
    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).isEmpty)
    #expect(try await SyncAdoptCheck.stored(under: old, in: scenario.log).isEmpty)
    #expect(try await SyncAdoptCheck.folds(adopter).isEmpty)
  }

  @Test("should give up held rows of files another adopter removed once they stayed unlisted for the abandon delay, and finish without deleting anything listed")
  func shouldFinishAfterOtherAdopterRemovedEverything() async throws {
    let scenario = try await SyncAdoptScenario.make(retire: false)
    try await scenario.adopter.lifecycle.retire(scenario.retiredID, successor: scenario.adopterID)
    try await scenario.bystander.lifecycle.retire(scenario.retiredID, successor: scenario.bystander.store.replica)
    _ = try await scenario.adopter.engine.upload()
    _ = try await scenario.bystander.engine.upload()
    scenario.world.advance(days: 31)
    let stored = try await SyncStoredFiles.read(scenario.retiredID, in: scenario.log)
    let base = try #require(stored.bases.values.first { $0.isComplete })
    let provider = SyncCompactProvider(wrapping: scenario.log)
    provider.delay(VaultPath.basePart(scenario.retiredID, upTo: base.point.last, tag: base.point.tag, part: base.parts, parts: base.parts), listings: 1)
    let slow = scenario.world.harness("bystander", store: scenario.bystander.store, provider: provider, configuration: scenario.settings)
    _ = try await slow.engine.start()

    #expect(try await slow.engine.adopt() == .inProgress([scenario.retiredID]))
    try await scenario.expectConverges(try await scenario.freshReader("slow"), "slow")
    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))
    try await scenario.expectConverges(try await scenario.freshReader("fast"), "fast")
    #expect(try await slow.engine.adopt() == .inProgress([scenario.retiredID]))
    scenario.world.advance(days: 29)
    #expect(try await slow.engine.adopt() == .inProgress([scenario.retiredID]))
    scenario.world.advance(days: 2)

    let outcomes = try await finishConverging(slow, in: scenario, "slow")

    #expect(outcomes.first == .adopted([scenario.retiredID]))
    #expect(try await SyncAdoptCheck.folds(slow).isEmpty)
    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).isEmpty)
    #expect(!provider.deleted.contains { $0.hasPrefix(VaultPath.segmentPrefix(scenario.retiredID)) })
  }

  @Test("should end a reader's coverage walk over adoption facts that form a cycle")
  func shouldStopOnCyclicFacts() async {
    await #expect(processExitsWith: .success) {
      guard try await cyclicFactsHoldSegment() else { throw SyncFixtureFailure("the segment behind the cyclic facts was not held") }
    }
  }

  @Test(
    "should not raise its head from another adopter's fact when it only applied that adopter's base, directly or through a fact that folded no base reaching it",
    arguments: [false, true])
  func shouldNotClaimAppliedBase(throughIntermediate: Bool) async throws {
    let scenario = try await SyncAdoptScenario.make()
    let retired = scenario.retired
    let late = once {
      try await retired.writeNotes(1, prefix: "late-", title: SyncAdoptScenario.title("late"))
      _ = try await retired.uploaded()
    }
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.published) { try await late() } })
    #expect(try await adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    let first = try #require(try await SyncAdoptCheck.facts(adopter).first)
    let leftover = try #require(try await scenario.log.listAll(prefix: VaultPath.segmentPrefix(scenario.retiredID)).first)
    _ = try await scenario.bystander.engine.sync()
    #expect(try await scenario.bystander.appliedFiles()[scenario.adopterID]?.hasBase(reaching: first.at) == true)
    let provider = SyncCompactProvider(wrapping: scenario.log)
    provider.hide(VaultPath.replicaPrefix(scenario.adopterID))
    let other = scenario.world.harness("bystander", store: scenario.bystander.store, provider: provider, configuration: scenario.settings)
    #expect(try await other.engine.start() == .alreadyRunning)
    let otherID = other.store.replica
    try await other.lifecycle.retire(scenario.adopterID, successor: otherID)
    if throughIntermediate {
      let middle = ReplicaID(UUID.v7())
      try await other.store.write { transaction in
        try ReplicaDirectory.recordAdoption(
          SyncAdoptionFact(adopted: scenario.adopterID, adopter: middle, through: first.at + 10, at: 1, baseUpTo: first.at - 1), in: &transaction)
        try SyncAdoptionTable.save(
          SyncAdoptionRow(adopted: middle, phase: .finished, through: 100, baseUpTo: 100, at: 1, completedBefore: 0), of: otherID, in: transaction.database)
      }
    }
    _ = try await other.engine.upload()
    scenario.world.advance(days: 31)

    #expect(try await other.engine.adopt() == .inProgress([scenario.retiredID]))

    #expect(try await SyncAdoptCheck.facts(other).filter { $0.adopted == scenario.retiredID && $0.adopter == otherID }.map(\.through) == [0])
    #expect(try await SyncAdoptCheck.folds(other)[scenario.retiredID]?[leftover.key]?.published == true)
    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).contains(leftover.key))
    #expect(!provider.deleted.contains(leftover.key))
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
  }

  @Test("should not delete a base part another engine on the same database folded after this call published, even when it completes that base")
  func shouldKeepPartFoldedByOtherEngine() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let stored = try await SyncStoredFiles.read(scenario.retiredID, in: scenario.log)
    let base = try #require(stored.bases.values.first { $0.isComplete })
    let last = VaultPath.basePart(scenario.retiredID, upTo: base.point.last, tag: base.point.tag, part: base.parts, parts: base.parts)
    scenario.adopterProvider.delay(last, listings: 2)
    #expect(try await scenario.adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    let foldOne = SyncAdoptProbe { step in if step == .adoption(.folded) { throw SyncFixtureFailure("stopped after one fold") } }
    let other = once {
      let harness = scenario.world.harness(
        "adopter", store: scenario.adopterStore, provider: SyncCompactProvider(wrapping: scenario.log), configuration: scenario.settings,
        compactionCheckpoint: foldOne.compaction, adoptionCheckpoint: foldOne.adoption)
      _ = try await harness.engine.start()
      guard (try? await harness.engine.adopt()) == nil else { throw SyncFixtureFailure("the other engine did not stop after its fold") }
    }
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.uploaded) { try await other() } })

    #expect(try await adopter.engine.adopt() == .inProgress([scenario.retiredID]))

    #expect(try await SyncAdoptCheck.folds(adopter)[scenario.retiredID]?[last]?.published == false)
    #expect(!scenario.adopterProvider.deleted.contains(last))
    try await scenario.expectConverges(try await scenario.freshReader("between"), "between")
    #expect(try await SyncAdoptCheck.finish(scenario.adopter).first == .adopted([scenario.retiredID]))
    try await scenario.expectAdopted(by: scenario.adopter)
    try await scenario.expectConverges(try await scenario.freshReader("after"), "after")
  }
}

/// Runs in a child process, so a walk over the cyclic facts that never ends fails this assertion instead of the test run.
private func cyclicFactsHoldSegment() async throws -> Bool {
  let world = SyncCompactWorld()
  let reader = try await world.started(world.harness("reader", store: try world.openStore(), configuration: adoptSettings), createsKey: true)
  let (adopted, first, second) = (ReplicaID(UUID.v7()), ReplicaID(UUID.v7()), ReplicaID(UUID.v7()))
  try await reader.store.write { transaction in
    try ReplicaDirectory.recordAdoption(SyncAdoptionFact(adopted: adopted, adopter: first, through: 5, at: 1, baseUpTo: 0), in: &transaction)
    try ReplicaDirectory.recordAdoption(SyncAdoptionFact(adopted: first, adopter: second, through: 10, at: 1, baseUpTo: 10), in: &transaction)
    try ReplicaDirectory.recordAdoption(SyncAdoptionFact(adopted: second, adopter: first, through: 10, at: 1, baseUpTo: 10), in: &transaction)
  }
  let writer = try SyncFixture.open()
  _ = try await writer.write { transaction in try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("cycle")), ["title": .string("held")]) }
  let lines = try await writer.pendingChanges(limit: .max).map(\.line)
  guard let key = reader.ring.writingKey() else { return false }
  let sealed = try await SyncPlant.segment(lines, replica: adopted, first: 2, previous: ReplicaFixture.point(1, 1), key: key, in: world.storage)
  guard case .segment(_, _, let last, let tag) = VaultPath.classify(sealed.key) else { return false }
  let outcome = try await reader.engine.download()
  return outcome.held[SyncFileID(replica: adopted, kind: .segment, point: StreamPoint(last: last, tag: tag))] == .waitingForPredecessor
}
