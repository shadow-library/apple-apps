import Foundation
import MemoirCore
import ShadowStore
import ShadowSyncRuntime

/// A quest's health threshold as its page and builder show it. It lives in the store of its metric's class, never in the quest's command.
nonisolated struct QuestThresholdSummary: Sendable, Hashable {
  /// The builder's one threshold (`quest-builder-screen.tsx:45`): steps at least 8,000.
  static let standardValue = DecimalText("8000")

  let metric: MetricReference
  /// Nil for a metric the owner defined and named.
  let builtin: BuiltinMetric?
  let customName: String?
  let value: DecimalText
  let comparison: ThresholdComparison

  static func standard(for quest: UUID) -> QuestThreshold? {
    standardValue.map { QuestThreshold(quest: quest, metric: BuiltinMetric.steps.reference, value: $0, comparison: .atLeast) }
  }

  static var standard: QuestThresholdSummary? {
    standardValue.map { QuestThresholdSummary(metric: BuiltinMetric.steps.reference, builtin: .steps, customName: nil, value: $0, comparison: .atLeast) }
  }

  var isStandard: Bool { self == Self.standard }
}

nonisolated enum QuestThresholdReader {
  static func load(_ quest: UUID, in stores: MemoirStores) async throws(StoreError) -> QuestThresholdSummary? {
    for syncClass in SyncClass.allCases {
      if let found = try await stores.store(of: syncClass).read({ transaction in try read(quest, syncClass, in: transaction) }) { return found }
    }
    return nil
  }

  /// While the vault syncs, a threshold kept in an activity or health store that does not sync to this device stays on the device that set it.
  static func mayLiveElsewhere(isSyncing: Bool, syncingRoutes: Set<SyncStoreRoute>) -> Bool {
    isSyncing && !(syncingRoutes.contains(MemoirSyncRoutes.activity) && syncingRoutes.contains(MemoirSyncRoutes.health))
  }

  /// Emits the quest's threshold once every class's store has been read, then again whenever one of them changes it.
  static func observe(_ quest: UUID, in stores: MemoirStores) -> AsyncThrowingStream<QuestThresholdSummary?, any Error> {
    let (events, sink) = AsyncThrowingStream<(SyncClass, QuestThresholdSummary?), any Error>.makeStream()
    let feeders = SyncClass.allCases.map { syncClass in
      Task {
        do {
          for try await found in stores.store(of: syncClass).observeReads({ transaction in try read(quest, syncClass, in: transaction) }) {
            sink.yield((syncClass, found))
          }
        } catch {
          sink.finish(throwing: error)
        }
      }
    }
    return AsyncThrowingStream { continuation in
      let merger = Task {
        var latest = [SyncClass: QuestThresholdSummary?]()
        var emitted: QuestThresholdSummary??
        do {
          for try await (syncClass, found) in events {
            latest[syncClass] = found
            guard latest.count == SyncClass.allCases.count else { continue }
            let current = SyncClass.allCases.lazy.compactMap { latest[$0] ?? nil }.first
            if emitted != .some(current) {
              emitted = .some(current)
              continuation.yield(current)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        merger.cancel()
        for feeder in feeders { feeder.cancel() }
        sink.finish()
      }
    }
  }

  private static func read(_ quest: UUID, _ syncClass: SyncClass, in transaction: ReadTransaction) throws(StoreError) -> QuestThresholdSummary? {
    switch syncClass {
    case .general: try read(quest, GeneralMetric.self, in: transaction)
    case .activity: try read(quest, ActivityMetric.self, in: transaction)
    case .health: try read(quest, HealthMetric.self, in: transaction)
    }
  }

  private static func read<Class: MetricClass>(_ quest: UUID, _: Class.Type, in transaction: ReadTransaction) throws(StoreError) -> QuestThresholdSummary? {
    guard let entry = try QuestThresholdRecord<Class>.read(id: quest, in: transaction).entry, !entry.isRemoved,
      let comparison = entry.record.comparison.known
    else { return nil }
    let metric = entry.record.metric
    let builtin = BuiltinMetric(id: metric.recordUUID)
    let customName = builtin == nil ? try MetricRecord<Class>.read(id: metric, in: transaction).entry?.record.name : nil
    return QuestThresholdSummary(
      metric: MetricReference(id: metric.recordUUID, metricClass: Class.syncClass), builtin: builtin, customName: customName, value: entry.record.value,
      comparison: comparison)
  }
}
