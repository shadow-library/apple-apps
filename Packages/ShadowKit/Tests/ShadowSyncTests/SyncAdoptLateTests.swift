import Foundation
import GRDB
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

private func segments(of replica: ReplicaID, in storage: any StorageProvider) async throws -> [(key: ObjectKey, id: SyncFileID)] {
  try await storage.listAll(prefix: VaultPath.segmentPrefix(replica)).compactMap { object in
    guard case .segment(_, _, let last, let tag) = VaultPath.classify(object.key) else { return nil }
    return (object.key, SyncFileID(replica: replica, kind: .segment, point: StreamPoint(last: last, tag: tag)))
  }
}

@Suite("SyncEngine adoption of files that arrive late")
struct SyncAdoptLateTests {
  @Test("should keep a segment the returning owner puts after the fold, release it to readers only with the adopter's base, and adopt it in a later pass")
  func shouldAdoptSegmentPutAfterFold() async throws {
    var settings = adoptSettings
    settings.compactionAge = SyncDays.duration(60)
    let scenario = try await SyncAdoptScenario.make(settings: settings)
    let retired = scenario.retired
    let fired = Mutex(false)
    let probe = SyncAdoptProbe { step in
      guard step == .adoption(.published), !fired.withLock({ $0 }) else { return }
      fired.withLock { $0 = true }
      try await retired.writeNotes(1, prefix: "late-", title: SyncAdoptScenario.title("late"))
      _ = try await retired.uploaded()
    }
    let adopter = try await scenario.engine(probe: probe)

    #expect(try await adopter.engine.adopt() == .inProgress([scenario.retiredID]))

    let late = try await segments(of: scenario.retiredID, in: scenario.log)
    #expect(late.count == 1)
    let left = Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log))
    #expect(left == [try #require(late.first).key, VaultPath.manifest(scenario.retiredID)])
    let first = try #require(try await SyncAdoptCheck.facts(adopter).first)

    let blindProvider = SyncCompactProvider(wrapping: scenario.log)
    blindProvider.hide(VaultPath.basePrefix(scenario.adopterID))
    let blind = try await scenario.world.started(
      scenario.world.harness("blind", store: try scenario.world.openStore(), provider: blindProvider, configuration: scenario.settings))
    #expect(try await blind.engine.download().held.values.contains(.waitingForDependency(scenario.retiredID)))
    for _ in 0..<40 where !(try await SyncAdoptCheck.facts(blind).contains(first)) { _ = try await blind.engine.download() }
    #expect(try await SyncAdoptCheck.facts(blind).contains(first))
    #expect(try await blind.engine.download().held[try #require(late.first).id] == .waitingForPredecessor)
    blindProvider.reveal()
    #expect(try await blind.engine.download().applied.contains(try #require(late.first).id))
    try await scenario.expectConverges(blind, "blind")
    let fresh = try await scenario.freshReader("fresh")
    #expect(try await fresh.engine.download().held.isEmpty)
    try await scenario.expectConverges(fresh, "fresh")

    #expect(try await adopter.engine.adopt() == .adopted([scenario.retiredID]))

    try await scenario.expectAdopted(by: adopter)
    let facts = try await SyncAdoptCheck.facts(adopter)
    #expect(facts.count == 2)
    let second = try #require(facts.first { $0 != first })
    #expect(second.through > first.through && second.at > first.at)
    try await scenario.expectConverges(try await scenario.freshReader("after"), "after")
    try await scenario.expectConverges(scenario.half, "half")
  }

  @Test("should keep a file a stale listing hid during the fold, release it to readers through the fact and adopt it in a later pass")
  func shouldAdoptFileHiddenDuringFold() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let hidden = try #require(try await segments(of: scenario.retiredID, in: scenario.log).max { $0.key < $1.key })
    scenario.adopterProvider.delay(hidden.key, listings: 1)

    #expect(try await scenario.adopter.engine.adopt() == .inProgress([scenario.retiredID]))

    #expect(Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log)) == [hidden.key, VaultPath.manifest(scenario.retiredID)])
    #expect(!scenario.adopterProvider.deleted.contains(hidden.key))
    let fresh = try await scenario.freshReader("fresh")
    let outcome = try await fresh.engine.download()
    #expect(outcome.applied.contains(hidden.id) && outcome.held.isEmpty)
    try await scenario.expectConverges(fresh, "fresh")

    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))

    try await scenario.expectAdopted(by: scenario.adopter)
    #expect(try await SyncAdoptCheck.facts(scenario.adopter).count == 2)
    try await scenario.expectConverges(try await scenario.freshReader("after"), "after")
  }

  @Test("should keep every part of a base that lists a part late, so a fresh reader can still apply it, and adopt the whole base in the next pass")
  func shouldKeepBaseWithLatePart() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let stored = try await SyncStoredFiles.read(scenario.retiredID, in: scenario.log)
    let base = try #require(stored.bases.values.first)
    #expect(stored.bases.count == 1 && base.isComplete && base.parts > 2)
    let keys = (1...base.parts).map { VaultPath.basePart(scenario.retiredID, upTo: base.point.last, tag: base.point.tag, part: $0, parts: base.parts) }
    scenario.adopterProvider.delay(try #require(keys.last), listings: 1)

    #expect(try await scenario.adopter.engine.adopt() == .inProgress([scenario.retiredID]))

    #expect(!scenario.adopterProvider.deleted.contains { $0.hasPrefix(VaultPath.replicaPrefix(scenario.retiredID)) })
    #expect(try await SyncStoredFiles.read(scenario.retiredID, in: scenario.log).bases[base.point]?.isComplete == true)
    #expect(try await SyncAdoptCheck.facts(scenario.adopter).map(\.through) == [0])
    try await scenario.expectConverges(try await scenario.freshReader("between"), "between")
    try await scenario.expectConverges(scenario.half, "half")

    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))
    try await scenario.expectAdopted(by: scenario.adopter)
    #expect(try await SyncAdoptCheck.facts(scenario.adopter).map(\.baseUpTo).max() == base.point.last)
    try await scenario.expectConverges(try await scenario.freshReader("after"), "after")
  }

  @Test("should keep the folded parts of a base whose other parts were never put until the delay passes, then delete them, losing nothing")
  func shouldAbandonIncompleteBaseAfterDelay() async throws {
    let scenario = try await SyncAdoptScenario.make(retire: false)
    try await scenario.retired.writeNotes(4, prefix: "r4-", title: SyncAdoptScenario.title("r4"))
    _ = try await scenario.retired.uploaded()
    let crashing = scenario.world.harness(
      "retired", store: scenario.retiredStore, configuration: scenario.settings, probe: SyncCompactionProbe(crashAt: 2))
    _ = try await crashing.engine.start()
    await #expect(throws: SyncError.self) { try await crashing.engine.compact(force: true) }
    let stored = try await SyncStoredFiles.read(scenario.retiredID, in: scenario.log)
    let incomplete = try #require(stored.bases.values.first { !$0.isComplete })
    #expect(incomplete.present == [1] && incomplete.parts > 1)
    let part = VaultPath.basePart(scenario.retiredID, upTo: incomplete.point.last, tag: incomplete.point.tag, part: 1, parts: incomplete.parts)
    try await scenario.retireAndWait()

    #expect(try await scenario.adopter.engine.adopt() == .inProgress([scenario.retiredID]))

    #expect(Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log)) == [part, VaultPath.manifest(scenario.retiredID)])
    try await scenario.expectConverges(try await scenario.freshReader("between"), "between")
    scenario.world.advance(days: 29)
    #expect(try await scenario.adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    scenario.world.advance(days: 2)

    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))

    try await scenario.expectAdopted(by: scenario.adopter)
    #expect(scenario.adopterProvider.deleted.contains(part))
    #expect(try await scenario.adopter.store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM sync_adoption_gap") } == 0)
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
    try await scenario.expectConverges(scenario.half, "half")
  }

  @Test("should publish only the contiguous head of what it folded and delete nothing beyond it, so a file hidden in the middle is adopted later")
  func shouldPublishContiguousHead() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let writer = try SyncFixture.open(wallClock: { scenario.world.clock.now })
    _ = try await writer.write { transaction in
      for index in 0..<15 { _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("g\(index)")), ["title": .string("gap \(index)")]) }
    }
    let lines = try await writer.pendingChanges(limit: .max).map(\.line)
    let key = try #require(scenario.adopter.ring.writingKey())
    var previous: StreamPoint?
    var planted: [SealedFile] = []
    for first in stride(from: 0, to: 15, by: 5) {
      let sealed = try await SyncPlant.segment(Array(lines[first..<first + 5]), replica: writer.replica, first: Int64(first + 1), previous: previous, key: key, in: scenario.log)
      previous = StreamPoint(last: Int64(first + 5), tag: sealed.tag)
      planted.append(sealed)
    }
    try await scenario.adopter.lifecycle.retire(writer.replica, successor: scenario.adopterID)
    scenario.world.advance(days: 31)
    scenario.adopterProvider.delay(planted[1].key, listings: 1)

    #expect(try await scenario.adopter.engine.adopt() == .progressed(adopted: [scenario.retiredID], waiting: [writer.replica]))

    #expect(try await SyncAdoptCheck.facts(scenario.adopter).filter { $0.adopted == writer.replica }.map(\.through) == [5])
    #expect(Set(try await SyncAdoptCheck.stored(under: writer.replica, in: scenario.log)) == [planted[1].key, planted[2].key])
    let fresh = try await scenario.freshReader("middle")
    try await scenario.expectConverges(fresh, "middle")
    #expect(try await fresh.engine.download().held.isEmpty)

    #expect(try await scenario.adopter.engine.adopt() == .adopted([writer.replica]))
    #expect(Set(try await SyncAdoptCheck.facts(scenario.adopter).filter { $0.adopted == writer.replica }.map(\.through)) == [5, 15])
    try await scenario.expectConverges(try await scenario.freshReader("after"), "after")
  }

  @Test("should delete nothing while its own base is not listed, and finish once it is")
  func shouldWaitForOwnBaseListing() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let before = Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log))
    scenario.adopterProvider.hide(VaultPath.basePrefix(scenario.adopterID))

    #expect(try await scenario.adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    #expect(try await scenario.adopter.engine.adopt() == .inProgress([scenario.retiredID]))

    #expect(Set(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log)) == before)
    #expect(scenario.adopterProvider.deleted.allSatisfy { !$0.hasPrefix(VaultPath.replicaPrefix(scenario.retiredID)) })
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
    scenario.adopterProvider.reveal()

    #expect(try await scenario.adopter.engine.adopt() == .adopted([scenario.retiredID]))
    try await scenario.expectAdopted(by: scenario.adopter)
  }
}
