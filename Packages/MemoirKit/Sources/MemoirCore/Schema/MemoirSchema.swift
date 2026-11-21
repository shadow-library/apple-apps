import ShadowAI
import ShadowJobs
import ShadowStore
import ShadowSync

public enum MemoirStoreKind: String, CaseIterable, Sendable {
  case main
  case activity
  case restricted

  public init(holding syncClass: SyncClass) {
    switch syncClass {
    case .general: self = .main
    case .activity: self = .activity
    case .health: self = .restricted
    }
  }

  public var syncClass: SyncClass {
    switch self {
    case .main: .general
    case .activity: .activity
    case .restricted: .health
    }
  }

  public var kinds: [MemoirKind] {
    MemoirKind.allCases.filter { $0.syncClass == syncClass }
  }

  public var registry: SchemaRegistry {
    switch self {
    case .main: MemoirSchema.mainRegistry
    case .activity: MemoirSchema.activityRegistry
    case .restricted: MemoirSchema.restrictedRegistry
    }
  }
}

public enum MemoirSchema {
  public static let mainVersion = 3
  public static let activityVersion = 3
  public static let restrictedVersion = 3

  static let journalRetention = 20

  public static let entities: [EntitySchema] = MemoirKind.allCases.map(schema(of:))

  /// The main store also holds the model-call ledger, AI consent and jobs, so insights route, ledger and run where their consent is kept.
  public static let mainRegistry = SyncKernelSchema.registry(version: mainVersion, adding: entities(of: .main) + LedgerSchema.entities + JobSchema.entities)
  public static let activityRegistry = SyncKernelSchema.registry(version: activityVersion, adding: entities(of: .activity))
  public static let restrictedRegistry = SyncKernelSchema.registry(version: restrictedVersion, adding: entities(of: .restricted))

  private static let byKind = Dictionary(uniqueKeysWithValues: zip(MemoirKind.allCases, entities))

  public static func entities(of store: MemoirStoreKind) -> [EntitySchema] {
    store.kinds.map(schema(of:))
  }

  static func rule(of kind: MemoirKind, field: String) -> FieldRule? {
    byKind[kind]?.rule(forField: field)
  }

  static func isRemovable(_ kind: MemoirKind) -> Bool {
    rule(of: kind, field: CommonField.removed.rawValue) != nil
  }

  private static func schema(of kind: MemoirKind) -> EntitySchema {
    switch kind {
    case .command, .commandNote:
      EntitySchema(kind: kind.entityKind, shape: .appended, syncClass: kind.syncClass)
    case .quest:
      record(kind, registers(QuestField.self))
    case .journalEntry:
      EntitySchema(
        kind: kind.entityKind,
        shape: .revisioned(
          fields: removable(registers(JournalEntryField.self, firstWriter: [.date, .loggedAtMillis])), marks: [], retention: .keepNewest(journalRetention)),
        syncClass: kind.syncClass)
    case .meal:
      record(kind, removable(registers(MealField.self, firstWriter: [.date, .preset, .loggedAtMillis])))
    case .mealPreset:
      record(kind, removable(registers(MealPresetField.self)))
    case .sideQuest:
      record(kind, removable(registers(SideQuestField.self, firstWriter: [.date, .loggedAtMillis])))
    case .expense:
      record(kind, removable(registers(ExpenseField.self, firstWriter: [.currency, .rate, .loggedAtMillis])))
    case .subscription:
      record(kind, removable(registers(SubscriptionField.self)))
    case .expenseCategory:
      record(kind, keyed(registers(ExpenseCategoryField.self)))
    case .receipt:
      record(kind, removable(registers(ReceiptField.self, firstWriter: Array(ReceiptField.allCases))))
    case .fxRate:
      record(kind, keyed(registers(FxRateField.self, firstWriter: [.rate])))
    case .accountSettings:
      record(kind, keyed(registers(AccountSettingsField.self)))
    case .generalMetric, .activityMetric, .healthMetric:
      record(kind, removable(registers(MetricField.self)))
    case .generalMetricDay, .activityMetricDay, .healthMetricDay:
      record(kind, removable(keyed(registers(MetricDayField.self))))
    case .weight:
      record(kind, removable(keyed(registers(WeightField.self))))
    case .generalQuestThreshold, .activityQuestThreshold, .healthQuestThreshold:
      record(kind, removable(registers(QuestThresholdField.self)))
    case .healthSettings:
      record(kind, keyed(registers(HealthSettingsField.self)))
    case .insightSchedule:
      record(kind, keyed(registers(InsightScheduleField.self)))
    case .generalInsight, .activityInsight, .healthInsight:
      record(kind, removable(registers(InsightField.self, firstWriter: Array(InsightField.allCases))))
    }
  }

  private static func record(_ kind: MemoirKind, _ fields: [String: FieldRule]) -> EntitySchema {
    EntitySchema(kind: kind.entityKind, shape: .record(fields: fields), syncClass: kind.syncClass)
  }

  private static func registers<Field: MemoirField>(_: Field.Type, firstWriter: [Field] = []) -> [String: FieldRule] {
    Dictionary(uniqueKeysWithValues: Field.allCases.map { field in (field.rawValue, firstWriter.contains(field) ? FieldRule.firstWriterWins : .register) })
  }

  private static func keyed(_ fields: [String: FieldRule]) -> [String: FieldRule] {
    fields.merging([CommonField.naturalKey.rawValue: .firstWriterWins]) { _, _ in preconditionFailure("natural_key is declared twice") }
  }

  private static func removable(_ fields: [String: FieldRule]) -> [String: FieldRule] {
    fields.merging([CommonField.removed.rawValue: .register]) { _, _ in preconditionFailure("removed is declared twice") }
  }
}
