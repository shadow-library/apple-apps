import Foundation
import MemoirCore
import OSLog
import ShadowAppShell
import ShadowStore

nonisolated enum HealthImportOutcome: Equatable, Sendable {
  /// This device cannot read Health, or reads no metric.
  case skipped
  /// Another device reads Health for the vault, or none does; this device cleared what it had indexed and the metrics it read.
  case notReader(HealthReaderDesignation?)
  case imported(HealthImportReport)
  case failed(code: String)
}

/// One Health import on this device, for the metrics it reads, with windows in the account's clock: the same run on a return to the foreground and when
/// the owner turns a metric on.
nonisolated struct HealthImportRunner: Sendable {
  private static let logger = Logger(subsystem: AppIdentity.memoir.id, category: "health")

  let environment: HealthEnvironment
  let stores: MemoirStores
  let clock: MemoirClock

  func run(_ metrics: Set<BuiltinMetric>? = nil, days: Int = HealthImport.defaultDays) async -> HealthImportOutcome {
    guard environment.canRead, let device = environment.device, let source = environment.source else { return .skipped }
    let chosen = metrics ?? environment.preferences.metrics
    guard !chosen.isEmpty else { return .skipped }
    let zone: AccountZone
    do {
      zone = try await AccountZone.load(from: stores.main)
    } catch {
      Self.logger.error("The account's zone could not be read for a Health import code=\(error.code, privacy: .public)")
      return .failed(code: error.code)
    }
    let importer = HealthImport(
      reader: HealthKitReader(source: source, deviceZone: clock.deviceZone), stores: stores, device: device, clock: clock.resolve(zone).clock, wallClock: clock.now)
    do throws(MetricsError) {
      let report = try await importer.run(BuiltinMetric.allCases.filter(chosen.contains), days: days)
      for (metric, failure) in report.failed {
        Self.logger.error("Health could not be read metric=\(metric.rawValue, privacy: .public) code=\(failure.code, privacy: .public)")
      }
      return .imported(report)
    } catch {
      if case .notReader(let designation) = error {
        environment.preferences.metrics = []
        return .notReader(designation)
      }
      Self.logger.error("The Health import failed code=\(error.code, privacy: .public)")
      return .failed(code: error.code)
    }
  }
}
