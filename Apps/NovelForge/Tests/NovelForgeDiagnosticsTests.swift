import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Novel Forge diagnostics", TestTimeLimit.standard)
struct NovelForgeDiagnosticsTests {
  @Test("should count the library's jobs by phase and name nothing else")
  func shouldCountTheLibrarysJobsByPhase() async throws {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall Lantern"), in: &transaction) }
    _ = try await Self.request(chapter: 1, of: novel, in: store)
    let running = try await Self.request(chapter: 2, of: novel, in: store)
    let now = LeaseInstant(date: Date(), source: .device)
    let start = AttemptStart(job: running, replica: store.replica, started: now, byHand: false, pinned: .null)
    _ = try await store.write { transaction in try AttemptRecords.start(try AttemptID(UUID.v7(at: now.date)), start, step: nil, in: &transaction) }

    let summary = await NovelForgeDiagnostics.summary(of: store)

    #expect(summary == ["jobs": .group(["queued": .count(1), "running": .count(1), "failed": .count(0), "cancelled": .count(0), "succeeded": .count(0)])])
    let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
    #expect(!encoded.contains("Ashfall"))
    #expect(!encoded.contains(novel.uuidString.lowercased()))
  }

  @Test("should add nothing while no library is open")
  func shouldAddNothingWhileNoLibraryIsOpen() async {
    #expect(await NovelForgeDiagnostics.summary(of: nil).isEmpty)
  }

  private static func request(chapter: Int, of novel: UUID, in store: VaultStore) async throws -> EntityRef {
    let key = try JobKey(
      scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.generate.rawValue, target: NovelJobAddress.target(chapter: chapter), fingerprint: "diagnostics",
      run: 1)
    let request = JobRequest(key: key, payload: .null, replica: store.replica)
    return try await store.write { transaction in try JobRecords.request(request, in: &transaction) }.job.ref
  }
}
