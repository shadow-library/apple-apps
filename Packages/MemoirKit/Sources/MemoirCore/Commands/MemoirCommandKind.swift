public enum OccurrenceUse: Sendable, Hashable {
  case required
  case optional
  case none
}

/// When a settings command takes effect. The reference stages a time-zone or intensity change and promotes it once the open day has closed
/// (`account.service.ts:137-139`, `rollover.service.ts:427-436`); its returner threshold applies at once, and so does the first time zone, which
/// onboarding sets outright (`account.service.ts:159-176`) because no day can be lived without one.
///
/// For replay: after a forward zone change the first day lived is the new zone's date, and the dates it jumps over were never lived, so they are not
/// closed with every quest missed (`rollover.service.ts:437-447`, `inNewZone`); after a backward change the open day stays open until the new zone's
/// date passes it. `firstDay` reads the account's day at the command, where the reference promotes at whichever rollover walk next reaches today, so
/// when the open day is stale (no command for some days) the reference keeps the old setting until that walk and replay applies it from the day after
/// the account's day, the same on every device.
public enum SettingTiming: Sendable, Hashable {
  case immediate
  case nextDayBoundary

  /// The first day lived under the new setting, given the account's day when the command was issued, `max(issuedOn, open day)`, since a backward zone
  /// change can leave the open day ahead of the zone's date (`rules/time.ts:157-161`). With no value in force yet it applies at once.
  public func firstDay(issuedOn: LocalDate, openDay: LocalDate?, replacingValueInForce: Bool) -> LocalDate? {
    let accountDay = max(issuedOn, openDay ?? issuedOn)
    switch (self, replacingValueInForce) {
    case (.immediate, _), (.nextDayBoundary, false): return accountDay
    case (.nextDayBoundary, true): return accountDay.adding(days: 1)
    }
  }
}

/// Every command type the reference registers (`quest-commands.service.ts:103-113`, `compassion-commands.service.ts:42-43`,
/// `metrics-commands.service.ts:60-63`, `finance-commands.service.ts:129-136`, `progression-commands.service.ts:42-44`,
/// `quick-logs-commands.service.ts:114-121`), the account settings that feed replay, and the receipt scan.
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
    case .accountSetTimeZone, .accountSetIntensityMode: .nextDayBoundary
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
