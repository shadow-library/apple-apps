import ShadowStore

public enum MemoirKind: String, CaseIterable, Sendable {
  case command = "mm_command"
  case commandNote = "mm_command_note"
  case quest = "mm_quest"
  case journalEntry = "mm_journal_entry"
  case meal = "mm_meal"
  case mealPreset = "mm_meal_preset"
  case sideQuest = "mm_side_quest"
  case expense = "mm_expense"
  case expenseCategory = "mm_expense_category"
  case subscription = "mm_subscription"
  case receipt = "mm_receipt"
  case fxRate = "mm_fx_rate"
  case accountSettings = "mm_account_settings"
  case generalMetric = "mm_metric_general"
  case generalMetricDay = "mm_metric_day_general"
  case activityMetric = "mm_metric_activity"
  case activityMetricDay = "mm_metric_day_activity"
  case healthMetric = "mm_metric_health"
  case healthMetricDay = "mm_metric_day_health"
  case weight = "mm_weight"

  public static func metric(_ syncClass: SyncClass) -> MemoirKind {
    switch syncClass {
    case .general: .generalMetric
    case .activity: .activityMetric
    case .health: .healthMetric
    }
  }

  public static func metricDay(_ syncClass: SyncClass) -> MemoirKind {
    switch syncClass {
    case .general: .generalMetricDay
    case .activity: .activityMetricDay
    case .health: .healthMetricDay
    }
  }

  public var syncClass: SyncClass {
    switch self {
    case .activityMetric, .activityMetricDay: .activity
    case .healthMetric, .healthMetricDay, .weight: .health
    case .command, .commandNote, .quest, .journalEntry, .meal, .mealPreset, .sideQuest, .expense, .expenseCategory, .subscription, .receipt, .fxRate, .accountSettings,
      .generalMetric, .generalMetricDay:
      .general
    }
  }

  public var entityKind: EntityKind {
    guard let kind = EntityKind(rawValue) else { preconditionFailure("\(rawValue) is a valid entity kind") }
    return kind
  }

  public init?(_ kind: EntityKind) {
    guard let match = Self.allCases.first(where: { $0.rawValue.utf8.elementsEqual(kind.rawValue.utf8) }) else { return nil }
    self = match
  }
}
