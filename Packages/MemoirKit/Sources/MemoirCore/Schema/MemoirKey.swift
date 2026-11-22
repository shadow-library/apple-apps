import Foundation
import ShadowCore
import ShadowStore

/// Natural keys: two devices that create the same thing create one entity. The hashed components and their order are frozen.
public enum MemoirKey: Hashable, Sendable {
  case expenseCategory(CategoryKey)
  case fxRate(base: CurrencyCode, quote: CurrencyCode, date: LocalDate)
  case metricDay(SyncClass, metric: UUID, date: LocalDate)
  case weight(LocalDate)
  case accountSettings
  case healthSettings
  case insightSchedule

  public static let scope = "com.shadow.library.memoircore"

  public var kind: MemoirKind {
    switch self {
    case .expenseCategory: .expenseCategory
    case .fxRate: .fxRate
    case .metricDay(let syncClass, _, _): MemoirKind.metricDay(syncClass)
    case .weight: .weight
    case .accountSettings: .accountSettings
    case .healthSettings: .healthSettings
    case .insightSchedule: .insightSchedule
    }
  }

  public var ref: EntityRef {
    EntityRef(kind: kind.entityKind, key: EntityKey.natural(scope: Self.scope, kind: kind.entityKind, components: members.map(\.text)))
  }

  public var stored: JSONValue {
    .object(Dictionary(uniqueKeysWithValues: members.map { ($0.name, JSONValue.string($0.text)) }))
  }

  public init(stored: JSONValue, of ref: EntityRef) throws(MemoirUnreadable) {
    guard let kind = MemoirKind(ref.kind), let members = stored.objectValue else { throw .invalid(field: CommonField.naturalKey.rawValue) }
    let reader = KeyReader(members: members)
    switch kind {
    case .expenseCategory:
      self = .expenseCategory(try reader.value("key", ["key"]))
    case .fxRate:
      let names = ["base", "quote", "date"]
      self = .fxRate(base: try reader.value("base", names), quote: try reader.value("quote", names), date: try reader.value("date", names))
    case .generalMetricDay, .activityMetricDay, .healthMetricDay:
      self = .metricDay(kind.syncClass, metric: try reader.value("metric", ["metric", "date"]), date: try reader.value("date", ["metric", "date"]))
    case .weight:
      self = .weight(try reader.value("date", ["date"]))
    case .accountSettings:
      guard members.isEmpty else { throw .invalid(field: CommonField.naturalKey.rawValue) }
      self = .accountSettings
    case .healthSettings:
      guard members.isEmpty else { throw .invalid(field: CommonField.naturalKey.rawValue) }
      self = .healthSettings
    case .insightSchedule:
      guard members.isEmpty else { throw .invalid(field: CommonField.naturalKey.rawValue) }
      self = .insightSchedule
    case .command, .commandNote, .quest, .journalEntry, .meal, .mealPreset, .sideQuest, .expense, .subscription, .receipt, .generalMetric, .activityMetric, .healthMetric,
      .generalQuestThreshold, .activityQuestThreshold, .healthQuestThreshold, .generalInsight, .activityInsight, .healthInsight, .expenseChange:
      throw .identity(ref)
    }
    guard self.ref == ref else { throw .keyMismatch(ref) }
  }

  private var members: [(name: String, text: String)] {
    switch self {
    case .expenseCategory(let key): [("key", key.key)]
    case .fxRate(let base, let quote, let date): [("base", base.code), ("quote", quote.code), ("date", date.isoString)]
    case .metricDay(_, let metric, let date): [("metric", metric.lowercasedString), ("date", date.isoString)]
    case .weight(let date): [("date", date.isoString)]
    case .accountSettings, .healthSettings, .insightSchedule: []
    }
  }
}

private struct KeyReader {
  let members: [String: JSONValue]

  func value<Value: StoredValue>(_ name: String, _ expected: [String]) throws(MemoirUnreadable) -> Value {
    guard members.count == expected.count, members.keys.allSatisfy({ key in expected.contains { $0.utf8.elementsEqual(key.utf8) } }) else {
      throw .invalid(field: CommonField.naturalKey.rawValue)
    }
    guard let json = members[name], let value = Value(stored: json) else { throw .invalid(field: CommonField.naturalKey.rawValue) }
    return value
  }
}
