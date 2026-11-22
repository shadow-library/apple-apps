import Foundation
import ShadowStore

/// One metric's definition, from the store of its class; a built-in metric not yet seeded there is shown with its built-in definition.
public struct MetricDescriptor: Sendable, Hashable {
  public let reference: MetricReference
  public let builtin: BuiltinMetric?
  public let name: String
  public let unit: String?
  public let valueType: StoredChoice<MetricValueType>
  public let direction: StoredChoice<MetricDirection>
}

/// A metric's day: the owner's entry wins over a Health import while it is set.
public struct MetricDayReading: Sendable, Hashable {
  public enum Source: Sendable, Hashable {
    case entry(StoredChoice<MetricEntrySource>)
    case imported
  }

  public let date: LocalDate
  public let value: DecimalText
  public let source: Source
}

public struct MetricSeries: Sendable, Hashable {
  public let metric: MetricDescriptor
  /// Every day of the window oldest first, `nil` where nothing was logged or imported.
  public let days: [DayValue<MetricDayReading>]
  public let today: MetricDayReading?
}

/// The metrics screen over the classes it was asked for, each read only from the store of its class. A quest whose threshold a day crosses is offered
/// for completion (`ThresholdOffers`), never completed.
public struct MetricsOverview: Sendable, Equatable {
  public static let trendDays = 14

  /// The classes whose stores this overview read.
  public let classes: Set<SyncClass>
  public let window: DateSpan
  public let series: [MetricSeries]
  public let offers: [ThresholdOffer]
  public let unreadable: Int
}

/// One class's metric records, read in that class's store.
struct MetricClassSnapshot: Sendable, Equatable {
  let syncClass: SyncClass
  let descriptors: [MetricDescriptor]
  let days: [MetricReference: [LocalDate: MetricDayReading]]
  let thresholds: [QuestThreshold]
  let unreadable: Int

  static func load(_ syncClass: SyncClass, in transaction: ReadTransaction) throws(StoreError) -> MetricClassSnapshot {
    try load(syncClass.metricClass, in: transaction)
  }

  private static func load<Class: MetricClass>(_: Class.Type, in transaction: ReadTransaction) throws(StoreError) -> MetricClassSnapshot {
    let metrics = try MetricRecord<Class>.listing(in: transaction)
    var descriptors = [UUID: MetricDescriptor]()
    for entry in metrics.entries where !entry.isRemoved {
      let record = entry.record
      let reference = MetricReference(id: record.id.recordUUID, metricClass: Class.syncClass)
      descriptors[reference.id] = MetricDescriptor(
        reference: reference, builtin: BuiltinMetric(id: reference.id), name: record.name, unit: record.unit, valueType: record.valueType,
        direction: record.direction)
    }
    let removed = Set(metrics.entries.filter(\.isRemoved).map(\.record.id.recordUUID))
    for builtin in BuiltinMetric.allCases where builtin.syncClass == Class.syncClass && descriptors[builtin.id] == nil && !removed.contains(builtin.id) {
      let definition = builtin.definition
      descriptors[builtin.id] = MetricDescriptor(
        reference: builtin.reference, builtin: builtin, name: definition.name, unit: definition.unit, valueType: .known(definition.valueType),
        direction: .known(definition.direction))
    }
    let dayListing = try MetricDayRecord<Class>.listing(in: transaction)
    var days = [MetricReference: [LocalDate: MetricDayReading]]()
    for entry in dayListing.entries where !entry.isRemoved {
      let record = entry.record
      guard let descriptor = descriptors[record.metric.recordUUID] else { continue }
      let reading: MetricDayReading? =
        if let owned = record.entry { MetricDayReading(date: record.date, value: owned.value, source: .entry(owned.source)) } else {
          record.imported.map { MetricDayReading(date: record.date, value: $0, source: .imported) }
        }
      if let reading { days[descriptor.reference, default: [:]][record.date] = reading }
    }
    let thresholdListing = try QuestThresholdRecord<Class>.listing(in: transaction)
    let thresholds = thresholdListing.entries.compactMap { entry -> QuestThreshold? in
      guard !entry.isRemoved, let descriptor = descriptors[entry.record.metric.recordUUID], let comparison = entry.record.comparison.known else { return nil }
      return QuestThreshold(quest: entry.record.quest, metric: descriptor.reference, value: entry.record.value, comparison: comparison)
    }
    return MetricClassSnapshot(
      syncClass: Class.syncClass,
      descriptors: descriptors.values.sorted { first, second in
        (first.builtin == nil ? 1 : 0, first.name, first.reference.id.uuidString) < (second.builtin == nil ? 1 : 0, second.name, second.reference.id.uuidString)
      }, days: days, thresholds: thresholds, unreadable: metrics.unreadable + dayListing.unreadable + thresholdListing.unreadable)
  }

  func values(of reference: MetricReference, in span: DateSpan) -> [MetricDayReading] {
    (days[reference] ?? [:]).filter { span.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
  }
}

/// What the metrics overview reads from the main store: quest names and the occurrences already logged in the window.
struct MetricQuestContext: Sendable, Equatable {
  let names: [UUID: String]
  let logged: Set<Occurrence>

  static func load(window: DateSpan, in transaction: ReadTransaction) throws(StoreError) -> MetricQuestContext {
    MetricQuestContext(
      names: try ReadSources.questNames(in: transaction), logged: Set(try ReadSources.questLogs(in: window, in: transaction).map(\.occurrence)))
  }
}

extension MetricsOverview {
  static func make(_ snapshots: [MetricClassSnapshot], quests: MetricQuestContext, activeQuests: [UUID], window: DateSpan, today: LocalDate) -> MetricsOverview {
    var series = [MetricSeries]()
    var thresholds = [QuestThreshold]()
    var days = [MetricDayValue]()
    for snapshot in snapshots {
      thresholds += snapshot.thresholds
      for descriptor in snapshot.descriptors {
        let readings = Dictionary(uniqueKeysWithValues: snapshot.values(of: descriptor.reference, in: window).map { ($0.date, $0) })
        series.append(
          MetricSeries(
            metric: descriptor, days: window.dates.map { DayValue(date: $0, value: readings[$0]) },
            today: snapshot.days[descriptor.reference]?[today]))
        days += readings.values.sorted { $0.date < $1.date }.map { MetricDayValue(metric: descriptor.reference, date: $0.date, value: $0.value) }
      }
    }
    let active = activeQuests.compactMap { id in quests.names[id].map { (id: id, name: $0) } }
    return MetricsOverview(
      classes: Set(snapshots.map(\.syncClass)), window: window, series: series,
      offers: ThresholdOffers.offers(thresholds: thresholds, days: days, activeQuests: active, logged: quests.logged),
      unreadable: snapshots.map(\.unreadable).reduce(0, +))
  }
}
