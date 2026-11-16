import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

/// A second adopter that adopts the first one, blind to the first adopted replica's prefix so it never adopts that replica itself.
private func adoptAdopter(_ scenario: SyncAdoptScenario) async throws -> SyncHarness {
  let provider = SyncCompactProvider(wrapping: scenario.log)
  provider.hide(VaultPath.replicaPrefix(scenario.retiredID))
  let second = scenario.world.harness("bystander", store: scenario.bystander.store, provider: provider, configuration: scenario.settings)
  #expect(try await second.engine.start() == .alreadyRunning)
  _ = try await second.engine.sync()
  try await second.lifecycle.retire(scenario.adopterID, successor: second.store.replica)
  _ = try await second.engine.upload()
  scenario.world.advance(days: 31)
  #expect(try await second.engine.adopt() == .adopted([scenario.adopterID]))
  #expect(try await SyncAdoptCheck.stored(under: scenario.adopterID, in: scenario.log).isEmpty)
  return second
}

@Suite("SyncEngine reader coverage of adopted replicas")
struct SyncAdoptCoverageTests {
  @Test("should release a leftover file of a replica through the adopter of its adopter, once that one folded the adopter's base")
  func shouldCoverThroughAdopterOfAdopter() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let retired = scenario.retired
    let late = once {
      try await retired.writeNotes(1, prefix: "late-", title: SyncAdoptScenario.title("late"))
      _ = try await retired.uploaded()
    }
    let adopter = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .adoption(.published) { try await late() } })
    #expect(try await adopter.engine.adopt() == .inProgress([scenario.retiredID]))
    let leftover = try #require(try await scenario.log.listAll(prefix: VaultPath.segmentPrefix(scenario.retiredID)).first)
    guard case .segment(_, _, let last, let tag) = VaultPath.classify(leftover.key) else { throw SyncFixtureFailure("not a segment") }
    let fact = try #require(try await SyncAdoptCheck.facts(adopter).first)

    let second = try await adoptAdopter(scenario)

    let carried = try #require(try await SyncAdoptCheck.facts(second).first { $0.adopted == scenario.adopterID })
    #expect(carried.baseUpTo >= fact.at)
    let reader = try await scenario.freshReader("unseen")
    try await SyncCompactCheck.drain(reader)
    #expect(try await reader.appliedFiles()[scenario.retiredID]?.segments.contains(StreamPoint(last: last, tag: tag)) == true)
    try await scenario.expectConverges(reader, "unseen")
  }

  @Test("should not release a replica through an adopter of its adopter that folded only the adopter's segments, which never hold adopted lines")
  func shouldNotCoverThroughSegmentsOnly() async throws {
    var settings = adoptSettings
    settings.compactionAge = SyncDays.duration(60)
    let scenario = try await SyncAdoptScenario.make(settings: settings)
    let stopped = try await scenario.engine(probe: SyncAdoptProbe { step in if step == .compaction(.settled) { throw SyncFixtureFailure("stopped before the base") } })
    await #expect(throws: SyncError.self) { try await stopped.engine.adopt() }
    let fact = try #require(try await SyncAdoptCheck.facts(stopped).first)
    #expect(try await SyncStoredFiles.read(scenario.adopterID, in: scenario.log).bases.isEmpty)

    let second = try await adoptAdopter(scenario)

    let folded = try #require(try await SyncAdoptCheck.facts(second).first { $0.adopted == scenario.adopterID })
    #expect(folded.through >= fact.at && folded.baseUpTo < fact.at)
    let provider = SyncCompactProvider(wrapping: scenario.log)
    provider.hide(VaultPath.replicaPrefix(scenario.retiredID))
    let reader = try await scenario.world.started(scenario.world.harness("blind", store: try scenario.world.openStore(), provider: provider, configuration: settings))
    let outcome = try await reader.engine.download()
    #expect(outcome.held.values.contains(.waitingForDependency(scenario.retiredID)))
  }
}
