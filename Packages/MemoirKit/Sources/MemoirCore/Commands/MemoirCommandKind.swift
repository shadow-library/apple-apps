public enum OccurrenceUse: Sendable, Hashable {
  case required
  case optional
  case none
}

/// When a settings command takes effect. The reference stages a time-zone or intensity change and promotes it when its rollover walk next prepares a day,
/// after every elapsed day has closed under the settings it was lived under (`account.service.ts:137-139`, `rollover.service.ts:369,427-436`); its
/// returner threshold applies at once, and so does the first time zone, which onboarding sets outright (`account.service.ts:159-176`) because no day can be
/// lived without one. Replay's day walk does the same, so the days an absence leaves close under the old setting.
public enum SettingTiming: Sendable, Hashable {
  case immediate
  /// Held until the day walk next prepares a day, which is then the first day lived under it.
  case staged

  /// With no value in force yet a staged setting applies at once.
  public func isStaged(replacingValueInForce: Bool) -> Bool {
    self == .staged && replacingValueInForce
  }
}

/// Every command type the reference registers (`quest-commands.service.ts:103-113`, `compassion-commands.service.ts:42-43`,
/// `metrics-commands.service.ts:60-63`, `finance-commands.service.ts:129-136`, `progression-commands.service.ts:42-44`,
/// `quick-logs-commands.service.ts:114-121`), the account settings that feed replay, the receipt scan, and money in the game (ruleset v2).
public enum MemoirCommandKind: String, CaseIterable, Sendable, Hashable {
  case questCreate = "quest.create"
  case questUpdate = "quest.update"
  case questDelete = "quest.delete"
  case questComplete = "quest.complete"
  case questPartial = "quest.partial"
  case questSkip = "quest.skip"
  case questPostpone = "quest.postpone"
  case questReschedule = "quest.reschedule"
  case questAttachReason = "quest.attachReason"
  case questEditLog = "quest.editLog"
  case questDeleteLog = "quest.deleteLog"
  case recoveryComplete = "recovery.complete"
  case planSetLock = "plan.setLock"
  case metricCreate = "metric.create"
  case metricUpdate = "metric.update"
  case metricDelete = "metric.delete"
  case metricRegister = "metric.register"
  case expenseCreate = "expense.create"
  case expenseUpdate = "expense.update"
  case expenseDelete = "expense.delete"
  case subscriptionCreate = "subscription.create"
  case subscriptionUpdate = "subscription.update"
  case subscriptionDelete = "subscription.delete"
  case subscriptionConfirmCycle = "subscription.confirmCycle"
  case categorySetArchived = "category.setArchived"
  case titleDisplay = "title.display"
  case cosmeticPurchase = "cosmetic.purchase"
  case cosmeticEquip = "cosmetic.equip"
  case journalSave = "journal.save"
  case mealLog = "meal.log"
  case mealLogPreset = "meal.logPreset"
  case mealSavePreset = "meal.savePreset"
  case mealPresetUpdate = "meal.preset.update"
  case mealPresetDelete = "meal.preset.delete"
  case weightSave = "weight.save"
  case sideQuestLog = "sidequest.log"
  case accountSetTimeZone = "account.setTimeZone"
  case accountSetIntensityMode = "account.setIntensityMode"
  case accountSetReturnerThreshold = "account.setReturnerThreshold"
  case receiptScan = "receipt.scan"
  case moneyNoSpend = "money.noSpend"
  case budgetClosePeriod = "budget.closePeriod"
  case goalMilestone = "goal.milestone"
  case goalBought = "goal.bought"

  public init?(_ type: CommandType) {
    guard let kind = Self.allCases.first(where: { $0.rawValue.utf8.elementsEqual(type.name.utf8) }) else { return nil }
    self = kind
  }

  public var commandType: CommandType {
    guard let type = try? CommandType(rawValue) else { preconditionFailure("\(rawValue) is a valid command type") }
    return type
  }

  public var occurrenceUse: OccurrenceUse {
    switch self {
    case .questComplete, .questPartial, .questSkip, .questPostpone, .questReschedule, .questAttachReason, .questEditLog, .questDeleteLog: .required
    case .metricRegister: .optional
    default: .none
    }
  }

  public var settingTiming: SettingTiming? {
    switch self {
    case .accountSetTimeZone, .accountSetIntensityMode: .staged
    case .accountSetReturnerThreshold: .immediate
    default: nil
    }
  }

  /// The only places an integer may appear in this type's payload: schedule minutes, counts and calendar positions, never a measurement.
  public var integerPaths: Set<String> {
    switch self {
    case .questCreate: QuestSchedule.integerPaths
    case .questUpdate: Set(QuestSchedule.integerPaths.map { "patch.\($0)" })
    case .questReschedule: ["toMin"]
    case .accountSetReturnerThreshold: ["returnerThresholdDays"]
    default: []
    }
  }
}
