import Foundation
import ShadowAppShell
import ShadowJobs
import ShadowStore

extension DiagnosticsSources {
  static func novelForge(store: VaultStore?, sync: SyncRuntimes, ai: AIServices) -> DiagnosticsSources {
    DiagnosticsSources(sync: sync, ai: ai, primary: store) { await NovelForgeDiagnostics.summary(of: store) }
  }
}

/// Novel Forge's part of a diagnostics report: how many of the library's jobs stand in each phase now.
nonisolated enum NovelForgeDiagnostics {
  static func summary(of store: VaultStore?, at now: Date = Date()) async -> [String: DiagnosticsValue] {
    guard let store else { return [:] }
    let instant = LeaseInstant(date: now, source: .device)
    do {
      let phases = try await store.read { transaction in
        var counts: [JobPhase: Int] = [:]
        for (ref, _) in try transaction.states(ofKind: JobSchema.jobKind) {
          guard let snapshot = try JobSnapshot.load(ref, in: transaction) else { continue }
          counts[JobStatus(snapshot, at: instant).phase, default: 0] += 1
        }
        return counts
      }
      return ["jobs": .group(Dictionary(uniqueKeysWithValues: JobPhase.allCases.map { ($0.rawValue, .count(phases[$0] ?? 0)) }))]
    } catch {
      return ["jobs": .code(error.code)]
    }
  }
}
