import Foundation
import ShadowCore
import ShadowStore

public protocol MetricClass: Sendable {
  static var syncClass: SyncClass { get }
}

public enum GeneralMetric: MetricClass {
  public static let syncClass = SyncClass.general
}

public enum ActivityMetric: MetricClass {
  public static let syncClass = SyncClass.activity
}

public enum HealthMetric: MetricClass {
  public static let syncClass = SyncClass.health
}

/// A metric's id carries its class, so a health metric's days cannot be written as another class's.
public struct MetricID<Class: MetricClass>: RecordIdentifier, CustomStringConvertible {
  public let recordUUID: UUID

  public init(recordUUID: UUID) {
    self.recordUUID = recordUUID
  }

  public init?(stored: JSONValue) {
    guard let id = UUID(stored: stored) else { return nil }
    recordUUID = id
  }

  public var stored: JSONValue { recordUUID.stored }

  public var description: String { recordUUID.lowercasedString }
}

public enum MetricValueType: String, CaseIterable, Hashable, Sendable {
  case number
  case duration
  case count
  case currency
  case boolean
  case text
}

public enum MetricDirection: String, CaseIterable, Hashable, Sendable {
  case higher
  case lower
  case range
  case neutral
}

/// A metric's class is its kind, so its definition and its days live in that class's store; changing the class is a delete and a create.
public struct MetricRecord<Class: MetricClass>: IdentifiedRecord, RemovableMemoirRecord {
  public static var kind: MemoirKind { MemoirKind.metric(Class.syncClass) }

  public let id: MetricID<Class>
  public var name: String
  public var unit: String?
  public var valueType: StoredChoice<MetricValueType>
  public var direction: StoredChoice<MetricDirection>
  public var defaultValue: DecimalText?
  public var glyph: String?

  public init(
    id: MetricID<Class>, name: String, unit: String? = nil, valueType: StoredChoice<MetricValueType>, direction: StoredChoice<MetricDirection>, defaultValue: DecimalText? = nil,
    glyph: String? = nil
  ) {
    self.id = id
    self.name = name
    self.unit = unit
    self.valueType = valueType
    self.direction = direction
    self.defaultValue = defaultValue
    self.glyph = glyph
  }

  public init(id: MetricID<Class>, reading reader: MemberReader<MetricField>) throws(MemoirUnreadable) {
    self.init(
      id: id, name: try reader.required(.name), unit: try reader.optional(.unit), valueType: try reader.required(.valueType), direction: try reader.required(.direction),
      defaultValue: try reader.optional(.defaultValue), glyph: try reader.optional(.glyph))
  }

  public var members: RecordMembers<MetricField> {
    var members = RecordMembers<MetricField>()
    members.put(.name, name)
    members.put(.unit, unit)
    members.put(.valueType, valueType)
    members.put(.direction, direction)
    members.put(.defaultValue, defaultValue)
    members.put(.glyph, glyph)
    return members
  }
}

/// The owner's own value for a metric's day, with the `metric.register` source token that wrote it; stored as one register.
public struct MetricEntry: Sendable, Hashable, StoredValue {
  public var value: DecimalText
  public var source: StoredChoice<MetricEntrySource>

  public init(value: DecimalText, source: StoredChoice<MetricEntrySource> = .known(.manual)) {
    self.value = value
    self.source = source
  }

  public init?(stored: JSONValue) {
    guard
      let entry = MemberReader<MetricEntryMember>.nested(
        stored, { reader throws(MemoirUnreadable) in MetricEntry(value: try reader.required(.value), source: try reader.required(.source)) })
    else { return nil }
    self = entry
  }

  public var stored: JSONValue {
    var members = RecordMembers<MetricEntryMember>()
    members.put(.value, value)
    members.put(.source, source)
    return members.json
  }
}

/// One summary per metric and day, keyed by both, so two devices reading the same day converge on one record. The owner's entry and the Health import
/// are separate registers, so neither overwrites the other when two devices write the day at once, and the owner's entry wins while it is set.
public struct MetricDayRecord<Class: MetricClass>: NaturalKeyRecord, RemovableMemoirRecord {
  public static var kind: MemoirKind { MemoirKind.metricDay(Class.syncClass) }

  public let metric: MetricID<Class>
  public let date: LocalDate
  public var entry: MetricEntry?
  public var imported: DecimalText?

  public init(metric: MetricID<Class>, date: LocalDate, entry: MetricEntry? = nil, imported: DecimalText? = nil) {
    self.metric = metric
    self.date = date
    self.entry = entry
    self.imported = imported
  }

  public init(key: MemoirKey, reading reader: MemberReader<MetricDayField>) throws(MemoirUnreadable) {
    guard case .metricDay(let syncClass, let metric, let date) = key, syncClass == Class.syncClass else { throw .identity(key.ref) }
    self.init(metric: MetricID(recordUUID: metric), date: date, entry: try reader.optional(.entry), imported: try reader.optional(.imported))
  }

  public var key: MemoirKey { .metricDay(Class.syncClass, metric: metric.recordUUID, date: date) }

  public var value: DecimalText? { entry?.value ?? imported }

  public var members: RecordMembers<MetricDayField> {
    var members = RecordMembers<MetricDayField>()
    members.put(.entry, entry)
    members.put(.imported, imported)
    return members
  }
}

public enum ThresholdComparison: String, CaseIterable, Hashable, Sendable {
  case atLeast = "gte"
  case atMost = "lte"
}

/// A quest's health threshold (`quests.health_threshold`), kept in the store of its metric's class because its value is that class's data; it is
/// identified by the quest's id, so a quest has at most one per class. Metric, value and comparison are one register, so they always change together.
public struct QuestThresholdRecord<Class: MetricClass>: IdentifiedRecord, RemovableMemoirRecord {
  public static var kind: MemoirKind { MemoirKind.questThreshold(Class.syncClass) }

  public let id: UUID
  public var metric: MetricID<Class>
  public var value: DecimalText
  public var comparison: StoredChoice<ThresholdComparison>

  public init(quest: UUID, metric: MetricID<Class>, value: DecimalText, comparison: StoredChoice<ThresholdComparison>) {
    id = quest
    self.metric = metric
    self.value = value
    self.comparison = comparison
  }

  public init(id: UUID, reading reader: MemberReader<QuestThresholdField>) throws(MemoirUnreadable) {
    let threshold: StoredThreshold<Class> = try reader.required(.threshold)
    self.init(quest: id, metric: threshold.metric, value: threshold.value, comparison: threshold.comparison)
  }

  public var quest: UUID { id }

  public var members: RecordMembers<QuestThresholdField> {
    var members = RecordMembers<QuestThresholdField>()
    members.put(.threshold, StoredThreshold(metric: metric, value: value, comparison: comparison))
    return members
  }
}

private struct StoredThreshold<Class: MetricClass>: StoredValue {
  let metric: MetricID<Class>
  let value: DecimalText
  let comparison: StoredChoice<ThresholdComparison>

  init(metric: MetricID<Class>, value: DecimalText, comparison: StoredChoice<ThresholdComparison>) {
    self.metric = metric
    self.value = value
    self.comparison = comparison
  }

  init?(stored: JSONValue) {
    guard
      let threshold = MemberReader<QuestThresholdMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) in
          StoredThreshold(metric: try reader.required(.metric), value: try reader.required(.value), comparison: try reader.required(.comparison))
        })
    else { return nil }
    self = threshold
  }

  var stored: JSONValue {
    var members = RecordMembers<QuestThresholdMember>()
    members.put(.metric, metric)
    members.put(.value, value)
    members.put(.comparison, comparison)
    return members.json
  }
}
