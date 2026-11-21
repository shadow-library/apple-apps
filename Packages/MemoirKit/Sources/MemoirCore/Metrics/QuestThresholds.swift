import Foundation
import ShadowCore
import ShadowStore

/// Writes a quest's threshold in the store of its metric's class, where its value belongs; the payload of `quest.create` and `quest.update` never
/// carries it. A quest keeps one threshold: setting it in one class removes it from the other two stores.
public enum QuestThresholds {
  public static func set(_ threshold: QuestThreshold, in stores: MemoirStores) async throws(MetricsError) {
    try await write(threshold, in: stores.store(of: threshold.metric.metricClass), threshold.metric.metricClass.metricClass)
    for other in SyncClass.allCases where other != threshold.metric.metricClass {
      try await remove(quest: threshold.quest, in: stores.store(of: other), other.metricClass)
    }
  }

  public static func clear(quest: UUID, in stores: MemoirStores) async throws(MetricsError) {
    for syncClass in SyncClass.allCases { try await remove(quest: quest, in: stores.store(of: syncClass), syncClass.metricClass) }
  }

  private static func write<Class: MetricClass>(_ threshold: QuestThreshold, in store: VaultStore, _: Class.Type) async throws(MetricsError) {
    let metric = MetricID<Class>(recordUUID: threshold.metric.id)
    let record = QuestThresholdRecord(quest: threshold.quest, metric: metric, value: threshold.value, comparison: .known(threshold.comparison))
    try await metricsCall { () async throws(StoreError) in
      try await store.write { transaction in
        try BuiltinMetric.seed(metric, in: &transaction)
        guard case .readable(let defined) = try MetricRecord<Class>.read(id: metric, in: transaction), !defined.isRemoved else {
          throw MetricsError.metricAbsent(threshold.metric)
        }
        switch try QuestThresholdRecord<Class>.read(id: threshold.quest, in: transaction) {
        case .absent:
          try record.create(in: &transaction)
        case .unreadable(let reason):
          throw MemoirRecordError.unreadable(record.ref, reason)
        case .readable(let current):
          if current.isRemoved { try QuestThresholdRecord<Class>.restore(record.ref, in: &transaction) }
          try QuestThresholdRecord<Class>.edit(id: threshold.quest, in: &transaction) { $0 = record }
        }
      }
    }
  }

  private static func remove<Class: MetricClass>(quest: UUID, in store: VaultStore, _: Class.Type) async throws(MetricsError) {
    try await metricsCall { () async throws(StoreError) in
      try await store.write { transaction in
        guard case .readable(let current) = try QuestThresholdRecord<Class>.read(id: quest, in: transaction), !current.isRemoved else { return }
        try QuestThresholdRecord<Class>.remove(QuestThresholdRecord<Class>.ref(quest), in: &transaction)
      }
    }
  }
}
