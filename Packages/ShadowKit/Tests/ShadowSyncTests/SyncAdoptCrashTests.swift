import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("SyncEngine adoption crash safety")
struct SyncAdoptCrashTests {
  @Test("should keep every uploaded change readable by a fresh and a half-synced reader at every checkpoint, and finish in a new engine without re-minting")
  func shouldSurviveCrashAtEveryCheckpoint() async throws {
    let dry = try await SyncAdoptScenario.make()
    let probe = SyncAdoptProbe()
    #expect(try await dry.engine(probe: probe).engine.adopt() == .adopted([dry.retiredID]))
    try await dry.expectAdopted(by: dry.adopter)
    let steps = probe.steps
    #expect(Set(steps.compactMap { step in if case .adoption(let reached) = step { reached } else { nil } }) == Set(SyncAdoptionStep.allCases))
    #expect(steps.filter { $0 == .adoption(.folded) }.count > 3)
    #expect(steps.filter { $0 == .compaction(.partPut) }.count > 1)
    #expect(steps.contains(.compaction(.completed)))

    for index in steps.indices {
      let scenario = try await SyncAdoptScenario.make()
      let crashing = try await scenario.engine(probe: SyncAdoptProbe(crashAt: index))
      let error = await #expect(throws: SyncError.self) { try await crashing.engine.adopt() }
      guard case .corruptState("injected crash")? = error else { throw SyncFixtureFailure("expected a crash at \(index) (\(steps[index])), got \(String(describing: error))") }

      try await scenario.expectConverges(try await scenario.freshReader("before-\(index)"), "before \(index) (\(steps[index]))")
      try await scenario.expectConverges(scenario.half, "half before \(index) (\(steps[index]))")
      let recovered = try await scenario.engine()
      try await SyncAdoptCheck.finish(recovered)
      try await scenario.expectAdopted(by: recovered)
      try await scenario.expectConverges(try await scenario.freshReader("after-\(index)"), "after \(index) (\(steps[index]))")
    }
  }
}
