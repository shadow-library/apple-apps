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

public enum MetricDaySource: String, CaseIterable, Hashable, Sendable {
  case manual
  case health
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

/// One summary per metric and day, keyed by both, so two devices reading the same day converge on one record.
public struct MetricDayRecord<Class: MetricClass>: NaturalKeyRecord, RemovableMemoirRecord {
  public static var kind: MemoirKind { MemoirKind.metricDay(Class.syncClass) }

  public let metric: MetricID<Class>
  public let date: LocalDate
  public var value: DecimalText
  public var source: StoredChoice<MetricDaySource>

  public init(metric: MetricID<Class>, date: LocalDate, value: DecimalText, source: StoredChoice<MetricDaySource>) {
    self.metric = metric
    self.date = date
    self.value = value
    self.source = source
  }

  public init(key: MemoirKey, reading reader: MemberReader<MetricDayField>) throws(MemoirUnreadable) {
    guard case .metricDay(let syncClass, let metric, let date) = key, syncClass == Class.syncClass else { throw .identity(key.ref) }
    self.init(metric: MetricID(recordUUID: metric), date: date, value: try reader.required(.value), source: try reader.required(.source))
  }

  public var key: MemoirKey { .metricDay(Class.syncClass, metric: metric.recordUUID, date: date) }

  public var members: RecordMembers<MetricDayField> {
    var members = RecordMembers<MetricDayField>()
    members.put(.value, value)
    members.put(.source, source)
    return members
  }
}
