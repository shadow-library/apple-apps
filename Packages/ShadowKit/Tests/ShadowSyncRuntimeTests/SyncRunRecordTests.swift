import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncRuntime

@Suite("Sync run record", TestTimeLimit.standard)
struct SyncRunRecordTests {
  @Test("should start empty and count successful runs once the runtime starts")
  func shouldStartEmptyAndCountSuccessfulRunsOnceTheRuntimeStarts() async throws {
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: ControlledProvider())
    defer { Task { await harness.runtime.shutdown() } }
    #expect(await harness.runtime.runRecord == SyncRunRecord())

    await harness.runtime.start()

    let record = await harness.runtime.runRecord
    #expect(record.runs > 0)
    #expect(record.failedRuns == 0)
    #expect(record.lastSucceeded != nil)
    #expect(record.lastFailed == nil)
    #expect(record.lastFailureCode == nil)
  }

  @Test("should count a write as unsent until its upload goes through")
  func shouldCountAWriteAsUnsentUntilItsUploadGoesThrough() async throws {
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: ControlledProvider())
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()

    try await harness.write("n1")
    #expect(await harness.runtime.runRecord.unsentWrites == 1)

    await harness.advance(by: .seconds(2))
    #expect(await harness.runtime.runRecord.unsentWrites == 0)
  }

  @Test("should record no failure for a run that ends at a condition it reports, such as full storage")
  func shouldRecordNoFailureForARunThatEndsAtACondition() async throws {
    let provider = ControlledProvider()
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: provider)
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()
    provider.failPuts(with: .quotaExceeded)

    try await harness.write("n1")
    await harness.advance(by: .seconds(2))

    #expect(harness.runtime.status == .attentionNeeded(.quotaFull))
    let record = await harness.runtime.runRecord
    #expect(record.failedRuns == 0)
    #expect(record.lastFailed == nil)
    #expect(record.lastFailureCode == nil)
    #expect(record.unsentWrites == 1)
  }

  @Test("should record a failed run's code without its message, and keep the code after the next run recovers")
  func shouldRecordAFailedRunsCodeWithoutItsMessage() async throws {
    let provider = ControlledProvider()
    let harness = try RuntimeHarness(InMemoryKeychain().device("phone"), provider: provider)
    defer { Task { await harness.runtime.shutdown() } }
    await harness.runtime.start()
    await harness.runtime.foreground()
    let before = provider.downloads
    provider.fail(.list, with: .unavailable("offline at Ashfall Lane"))

    #expect(try await harness.advanceTimer(by: .seconds(45)) { provider.downloads == before + 1 })
    let failed = await harness.runtime.runRecord
    #expect(failed.failedRuns == 1)
    #expect(failed.consecutiveFailures == 1)
    #expect(failed.lastFailed != nil)
    let code = try #require(failed.lastFailureCode)
    #expect(!code.contains("Ashfall"))
    #expect(code == SyncError.storage(.unavailable("offline at Ashfall Lane")).code)

    #expect(try await harness.advanceTimer(by: .seconds(2)) { provider.downloads == before + 2 })
    let recovered = await harness.runtime.runRecord
    #expect(recovered.consecutiveFailures == 0)
    #expect(recovered.failedRuns == 1)
    #expect(recovered.lastFailureCode == code)
    #expect(try #require(recovered.lastSucceeded) >= (failed.lastSucceeded ?? .distantPast))
  }
}
