import Foundation
import ShadowCore
import ShadowStore

public struct QuestThreshold: Sendable, Hashable {
  public let quest: UUID
  public let metric: MetricReference
  public let value: DecimalText
  public let comparison: ThresholdComparison

  public init(quest: UUID, metric: MetricReference, value: DecimalText, comparison: ThresholdComparison) {
    self.quest = quest
    self.metric = metric
    self.value = value
    self.comparison = comparison
  }

  public func isCrossed(by current: DecimalText) -> Bool {
    switch comparison {
    case .atLeast: current >= value
    case .atMost: current <= value
    }
  }
}

public struct MetricDayValue: Sendable, Hashable {
  public let metric: MetricReference
  public let date: LocalDate
  public let value: DecimalText

  public init(metric: MetricReference, date: LocalDate, value: DecimalText) {
    self.metric = metric
    self.date = date
    self.value = value
  }
}

public struct ThresholdOffer: Sendable, Hashable {
  public let quest: UUID
  public let questName: String
  public let metric: MetricReference
  public let date: LocalDate
  public let thresholdValue: DecimalText
  public let currentValue: DecimalText
  public let comparison: ThresholdComparison
}

/// `threshold-offer.ts`: a quest whose threshold a metric's day crosses is offered for completion on that date unless the occurrence already has a log.
/// Like the reference, which offers only for `is_health` metrics, a general metric's day never offers.
/// Offers are a read and never write; only the owner's own `quest.complete` grants the reward, so replay gives the same result on a device that holds
/// none of the metrics. Which quests are active and which occurrences have a log is replay's, so the caller passes both.
public enum ThresholdOffers {
  /// Offers in the reference's order: by metric, then day, then quest as `activeQuests` lists them.
  public static func offers(
    thresholds: [QuestThreshold], days: [MetricDayValue], activeQuests: [(id: UUID, name: String)], logged: Set<Occurrence>
  ) -> [ThresholdOffer] {
    let byQuest = Dictionary(grouping: thresholds, by: \.quest)
    var offers = [ThresholdOffer]()
    for day in days where day.metric.metricClass != .general {
      for quest in activeQuests {
        for threshold in byQuest[quest.id] ?? [] where threshold.metric == day.metric && threshold.isCrossed(by: day.value) {
          guard !logged.contains(Occurrence(quest: quest.id, date: day.date)) else { continue }
          offers.append(
            ThresholdOffer(
              quest: quest.id, questName: quest.name, metric: day.metric, date: day.date, thresholdValue: threshold.value, currentValue: day.value,
              comparison: threshold.comparison))
        }
      }
    }
    return offers
  }

  /// The full current offer set over every class's stored thresholds and days. A threshold or day of a removed or absent metric offers nothing, and
  /// quests without a readable name in the main store are skipped.
  public static func current(in stores: MemoirStores, activeQuests: [UUID], logged: Set<Occurrence>) async throws(MetricsError) -> [ThresholdOffer] {
    var thresholds = [QuestThreshold]()
    var days = [MetricDayValue]()
    for syncClass in SyncClass.allCases where syncClass != .general {
      let stored = try await stored(in: stores.store(of: syncClass), syncClass.metricClass)
      thresholds += stored.thresholds
      days += stored.days
    }
    guard !thresholds.isEmpty, !days.isEmpty else { return [] }
    let quests = try await metricsCall { () async throws(StoreError) in
      try await stores.main.read { transaction in
        try activeQuests.compactMap { id -> (id: UUID, name: String)? in
          guard case .readable(let entry) = try QuestRecord.read(id: id, in: transaction) else { return nil }
          return (id, entry.record.name)
        }
      }
    }
    return offers(thresholds: thresholds, days: days, activeQuests: quests, logged: logged)
  }

  private static func stored<Class: MetricClass>(in store: VaultStore, _: Class.Type) async throws(MetricsError) -> (thresholds: [QuestThreshold], days: [MetricDayValue]) {
    try await metricsCall { () async throws(StoreError) in
      try await store.read { transaction in
        let metrics = Set(try MetricRecord<Class>.listing(in: transaction).entries.filter { !$0.isRemoved }.map(\.record.id))
        let thresholds = try QuestThresholdRecord<Class>.listing(in: transaction).entries.compactMap { entry -> QuestThreshold? in
          guard !entry.isRemoved, metrics.contains(entry.record.metric), let comparison = entry.record.comparison.known else { return nil }
          return QuestThreshold(
            quest: entry.record.quest, metric: MetricReference(id: entry.record.metric.recordUUID, metricClass: Class.syncClass), value: entry.record.value,
            comparison: comparison)
        }
        let days = try MetricDayRecord<Class>.listing(in: transaction).entries.compactMap { entry -> MetricDayValue? in
          guard !entry.isRemoved, metrics.contains(entry.record.metric), let value = entry.record.value else { return nil }
          return MetricDayValue(metric: MetricReference(id: entry.record.metric.recordUUID, metricClass: Class.syncClass), date: entry.record.date, value: value)
        }
        return (thresholds, days.sorted { ($0.metric.id.uuidString, $0.date) < ($1.metric.id.uuidString, $1.date) })
      }
    }
  }
}
