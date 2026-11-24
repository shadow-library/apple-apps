import Foundation
import ShadowCore
import ShadowStore

/// `recovery.complete`: the reflection's text, when attached, is the command's note record.
public struct RecoveryCompletion: Sendable, Hashable {
  public let hasReflection: Bool

  public init(hasReflection: Bool = false) {
    self.hasReflection = hasReflection
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    self.init(hasReflection: try AttachedText.read("reflectionText", from: &reader, allowsClear: false) == .set)
  }

  func write(to writer: inout PayloadWriter) {
    AttachedText.write(hasReflection ? .set : .keep, "reflectionText", to: &writer)
  }
}

/// `plan.setLock`. The reference reads `locked !== true` as an unlock and ignores the quest ids then; it refuses a repeated id as an unknown quest
/// (`LCK_001`), since its lookup returns each quest once.
public enum PlanLock: Sendable, Hashable {
  case unlocked
  case locked([UUID])

  public init(locking questIds: [UUID]) throws(CommandRefusal) {
    guard !questIds.isEmpty else { throw .invalidField(field: "questIds", problem: .required) }
    guard Set(questIds).count == questIds.count else { throw .duplicateLockedQuest }
    self = .locked(questIds)
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    guard try reader.bool("locked", default: false) else {
      self = .unlocked
      return
    }
    guard let entries = reader.value("questIds")?.arrayValue, !entries.isEmpty else { throw .invalidField(field: "questIds", problem: .required) }
    var questIds = [UUID]()
    for entry in entries {
      guard let id = UUID(stored: entry) else { throw .invalidField(field: "questIds", problem: .notIdentifier) }
      questIds.append(id)
    }
    try self.init(locking: questIds)
  }

  func write(to writer: inout PayloadWriter) {
    switch self {
    case .unlocked:
      writer.put("locked", false)
    case .locked(let questIds):
      writer.put("locked", true)
      writer.put("questIds", questIds)
    }
  }
}

/// A metric's class is part of its kind, so a command names the class with the id to say which store holds the record.
public struct MetricReference: Sendable, Hashable {
  public let id: UUID
  public let metricClass: SyncClass

  public init(id: UUID, metricClass: SyncClass) {
    self.id = id
    self.metricClass = metricClass
  }

  init(reading reader: inout PayloadReader, idKey: String = "id") throws(CommandRefusal) {
    let id = try reader.uuid(idKey)
    self.init(id: id, metricClass: try reader.choice("metricClass", as: SyncClass.self))
  }

  func write(to writer: inout PayloadWriter, idKey: String = "id") {
    writer.put(idKey, id)
    writer.put("metricClass", token: metricClass)
  }
}

public struct MetricDeletion: Sendable, Hashable {
  public let metric: MetricReference
  public let detach: Bool

  public init(metric: MetricReference, detach: Bool = false) {
    self.metric = metric
    self.detach = detach
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let metric = try MetricReference(reading: &reader)
    self.init(metric: metric, detach: try reader.bool("detach", default: false))
  }

  func write(to writer: inout PayloadWriter) {
    metric.write(to: &writer)
    writer.put("detach", detach)
  }
}

public enum MetricEntrySource: String, RuleKey {
  case questLog = "quest_log"
  case manual
  case food
}

/// The value is the metric's day record in the store of its class, keyed by metric and date; the reference's `questLogId` is the command's occurrence.
public struct MetricRegistration: Sendable, Hashable {
  public let metric: MetricReference
  public let date: LocalDate
  public let source: MetricEntrySource
  public let questLog: Occurrence?

  public init(metric: MetricReference, date: LocalDate, source: MetricEntrySource = .manual, questLog: Occurrence? = nil) {
    self.metric = metric
    self.date = date
    self.source = source
    self.questLog = questLog
  }

  init(reading reader: inout PayloadReader, occurrence: Occurrence?) throws(CommandRefusal) {
    let metric = try MetricReference(reading: &reader, idKey: "metricId")
    let date = try reader.date("date")
    let source = reader.contains("source") ? try reader.choice("source", as: MetricEntrySource.self) : .manual
    self.init(metric: metric, date: date, source: source, questLog: occurrence)
  }

  func write(to writer: inout PayloadWriter) {
    metric.write(to: &writer, idKey: "metricId")
    writer.put("date", date)
    writer.put("source", token: source)
  }
}

/// A record the command names by its `id`; everything else about it is in the record.
public struct RecordReference: Sendable, Hashable {
  public let id: UUID

  public init(id: UUID) {
    self.id = id
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    self.init(id: try reader.uuid("id"))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("id", id)
  }
}

public enum ExpenseSource: String, RuleKey {
  case manual
  case ocr
}

/// `occurredOn`, the expense's own date, is what lets the creation cover that day's money logging; it arrived with ruleset v2.
public struct ExpenseCreation: Sendable, Hashable {
  public let id: UUID
  public let source: ExpenseSource
  public let occurredOn: LocalDate?

  public init(id: UUID, source: ExpenseSource = .manual, occurredOn: LocalDate? = nil) {
    self.id = id
    self.source = source
    self.occurredOn = occurredOn
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let id = try reader.uuid("id")
    let source = reader.contains("source") ? try reader.choice("source", as: ExpenseSource.self) : .manual
    self.init(id: id, source: source, occurredOn: reader.contains("occurredOn") ? try reader.date("occurredOn") : nil)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("id", id)
    writer.put("source", token: source)
    writer.put("occurredOn", occurredOn)
  }
}

/// Finance's `CycleConfirmation`, under the reference's keys: `id` is the subscription. The cycle's expense id is derived from the subscription and the
/// billing date (`SubscriptionCycles.expenseID`), so the payload carries none.
extension CycleConfirmation {
  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let subscription = try reader.uuid("id")
    self.init(subscription: subscription, billingDate: try reader.date("billingDate"))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("id", subscription)
    writer.put("billingDate", billingDate)
  }
}

/// `category.setArchived` over the reference's nine built-in categories, the only ones it has (`expense-category.repository.ts`); another key is not found
/// (`FIN_005`), and the uncategorised and subscriptions categories stay (`FIN_007`).
public struct CategoryArchival: Sendable, Hashable {
  public static let builtInCategories: Set<String> = ["food", "groceries", "transport", "bills", "health", "shopping", "home", "subs", "uncat"]
  public static let permanentCategories: Set<String> = ["uncat", "subs"]

  public let categoryId: CategoryKey
  public let archived: Bool

  public init(categoryId: CategoryKey, archived: Bool) throws(CommandRefusal) {
    if archived && Self.permanentCategories.contains(categoryId.key) { throw .categoryNotArchivable(categoryId) }
    guard Self.builtInCategories.contains(categoryId.key) else { throw .unknownCategory(categoryId.key) }
    self.categoryId = categoryId
    self.archived = archived
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let text = try reader.string("categoryId")
    guard let archived = reader.value("archived")?.boolValue else { throw .invalidField(field: "archived", problem: .notBoolean) }
    guard let categoryId = CategoryKey(text) else { throw .unknownCategory(text) }
    try self.init(categoryId: categoryId, archived: archived)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("categoryId", categoryId)
    writer.put("archived", archived)
  }
}

/// `title.display`: `nil` shows none. Whether the title was earned is for replay; an id outside the catalogue can never have been (`TTL_001`).
public struct TitleDisplay: Sendable, Hashable {
  public let title: TitleID?

  public init(title: TitleID?) {
    self.title = title
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    switch reader.value("titleId") {
    case .null?:
      self.init(title: nil)
    case .string(let text)?:
      guard let title = TitleID.allCases.first(where: { $0.rawValue.utf8.elementsEqual(text.utf8) }) else { throw .unknownTitle(text) }
      self.init(title: title)
    default:
      throw .invalidField(field: "titleId", problem: .notString)
    }
  }

  func write(to writer: inout PayloadWriter) {
    guard let title else { return writer.putNull("titleId") }
    writer.put("titleId", token: title)
  }
}

/// The reference's cosmetic catalogue (`progression/cosmetic.catalogue.ts`), without its display names: an item is bought with coins or unlocked by an
/// achievement, never both.
public enum CosmeticID: String, RuleKey {
  case badgeBronze = "badge_bronze"
  case badgeSilver = "badge_silver"
  case badgeGoldStreak = "badge_gold_streak"
  case accentEmber = "accent_ember"
  case accentFrost = "accent_frost"
  case accentAuroraPlatinum = "accent_aurora_platinum"
  case themeSunrise = "theme_sunrise"
  case themeMidnight = "theme_midnight"
  case themeReturner = "theme_returner"

  public enum Kind: String, RuleKey {
    case badge
    case heroAccent = "hero_accent"
    case themeAccent = "theme_accent"
  }

  public var kind: Kind {
    switch self {
    case .badgeBronze, .badgeSilver, .badgeGoldStreak: .badge
    case .accentEmber, .accentFrost, .accentAuroraPlatinum: .heroAccent
    case .themeSunrise, .themeMidnight, .themeReturner: .themeAccent
    }
  }

  public var priceCoins: Int? {
    switch self {
    case .badgeBronze: 50
    case .badgeSilver: 150
    case .accentEmber, .accentFrost: 100
    case .themeSunrise, .themeMidnight: 75
    case .badgeGoldStreak, .accentAuroraPlatinum, .themeReturner: nil
    }
  }

  public var unlockedBy: AchievementID? {
    switch self {
    case .badgeGoldStreak: .firstGoldStreak
    case .accentAuroraPlatinum: .firstPlatinumStreak
    case .themeReturner: .firstReturnerRitual
    case .badgeBronze, .badgeSilver, .accentEmber, .accentFrost, .themeSunrise, .themeMidnight: nil
    }
  }

  static func read(_ reader: inout PayloadReader, forSale: Bool) throws(CommandRefusal) -> CosmeticID {
    let text = try reader.string("cosmeticId")
    guard let cosmetic = allCases.first(where: { $0.rawValue.utf8.elementsEqual(text.utf8) }) else { throw .unknownCosmetic(text) }
    if forSale && cosmetic.priceCoins == nil { throw .cosmeticNotForSale(cosmetic) }
    return cosmetic
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("cosmeticId", token: self)
  }
}

/// A journal entry or a meal: the entry's record holds its words and values; the command keeps the date it was logged for, which decides the reward.
public struct QuickLogEntry: Sendable, Hashable {
  public let id: UUID
  public let date: LocalDate

  public init(id: UUID, date: LocalDate) {
    self.id = id
    self.date = date
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    var draft = try QuickLogDraft.reader(&reader)
    let id = try reader.uuid("id")
    let date = try draft.date("date")
    try draft.finish()
    self.init(id: id, date: date)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("id", id)
    var draft = PayloadWriter()
    draft.put("date", date)
    writer.put("draft", draft)
  }
}

/// The reference's `requireObject(payload, 'draft')` names the draft's own fields without a prefix.
enum QuickLogDraft {
  static func reader(_ reader: inout PayloadReader) throws(CommandRefusal) -> PayloadReader {
    guard let value = reader.value("draft"), let members = value.objectValue else { throw .invalidField(field: "draft", problem: .required) }
    return PayloadReader(members)
  }
}

public struct PresetMealEntry: Sendable, Hashable {
  public let id: UUID
  public let presetId: UUID
  public let date: LocalDate

  public init(id: UUID, presetId: UUID, date: LocalDate) {
    self.id = id
    self.presetId = presetId
    self.date = date
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let presetId = try reader.uuid("presetId")
    let date = try reader.date("date")
    self.init(id: try reader.uuid("id"), presetId: presetId, date: date)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("id", id)
    writer.put("presetId", presetId)
    writer.put("date", date)
  }
}

/// The weight itself is the restricted store's record for the date; replacing a day's weight needs `confirmedReplacement`.
public struct WeightEntry: Sendable, Hashable {
  public let date: LocalDate
  public let confirmedReplacement: Bool

  public init(date: LocalDate, confirmedReplacement: Bool = false) {
    self.date = date
    self.confirmedReplacement = confirmedReplacement
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let date = try reader.date("date")
    self.init(date: date, confirmedReplacement: try reader.bool("confirmedReplacement", default: false))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("date", date)
    writer.put("confirmedReplacement", confirmedReplacement)
  }
}

public struct SideQuestEntry: Sendable, Hashable {
  public let id: UUID
  public let date: LocalDate
  public let statAffinity: StatAffinity?

  public init(id: UUID, date: LocalDate, statAffinity: StatAffinity? = nil) {
    self.id = id
    self.date = date
    self.statAffinity = statAffinity
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    var draft = try QuickLogDraft.reader(&reader)
    let id = try reader.uuid("id")
    let date = try draft.date("date")
    let statAffinity = draft.contains("statAffinity") ? try draft.choice("statAffinity", as: StatAffinity.self) : nil
    try draft.finish()
    self.init(id: id, date: date, statAffinity: statAffinity)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("id", id)
    var draft = PayloadWriter()
    draft.put("date", date)
    draft.put("statAffinity", token: statAffinity)
    writer.put("draft", draft)
  }
}

/// An IANA zone identifier in its canonical spelling: `UTC`, `GMT`, or an `Area/Location` path whose segments start with an upper-case letter. Decoding
/// checks only that shape, so a device with older zone data still replays a zone it does not know the same way; issuing also requires this device's
/// zone data to know the zone under exactly that name, which refuses offsets (`GMT+5`, `UTC+3`, `+05:00`), a lower-case spelling and the legacy
/// one-word zones (`CET`, `Japan`).
public struct TimeZoneChange: Sendable, Hashable {
  public static let maximumLength = 64

  public let identifier: String

  public init(identifier: String) throws(CommandRefusal) {
    guard Self.isIdentifier(identifier), Self.isKnown(identifier) else { throw .invalidField(field: "timezone", problem: .notAllowed) }
    self.identifier = identifier
  }

  private init(decoded identifier: String) {
    self.identifier = identifier
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let identifier = try reader.string("timezone")
    guard Self.isIdentifier(identifier) else { throw .invalidField(field: "timezone", problem: .notAllowed) }
    self.init(decoded: identifier)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("timezone", identifier)
  }

  /// Foundation names UTC `GMT`; every other zone must come back under the name it was asked for.
  private static func isKnown(_ identifier: String) -> Bool {
    guard let resolved = TimeZone(identifier: identifier)?.identifier else { return false }
    return resolved == identifier || (identifier == "UTC" && resolved == "GMT")
  }

  private static func isIdentifier(_ text: String) -> Bool {
    guard text.utf8.count <= maximumLength else { return false }
    if text == "UTC" || text == "GMT" { return true }
    let segments = Array(text.utf8).split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    let punctuation: [UInt8] = [UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "+")]
    return segments.count >= 2
      && segments.allSatisfy { segment in
        guard let first = segment.first, (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) else { return false }
        return segment.allSatisfy { CommandPayload.isAlphanumeric($0) || punctuation.contains($0) }
      }
  }
}

public struct IntensityModeChange: Sendable, Hashable {
  public let mode: IntensityMode

  public init(mode: IntensityMode) {
    self.mode = mode
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    self.init(mode: try reader.choice("intensityMode", as: IntensityMode.self))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("intensityMode", token: mode)
  }
}

/// `returnerThresholdDays` between 1 and 90, as the reference's account patch schema declares it.
public struct ReturnerThresholdChange: Sendable, Hashable {
  public static let days = 1...90

  public let days: Int

  public init(days: Int) throws(CommandRefusal) {
    guard Self.days.contains(days) else { throw .invalidField(field: "returnerThresholdDays", problem: .outOfRange) }
    self.days = days
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    try self.init(days: try reader.integer("returnerThresholdDays"))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("returnerThresholdDays", days)
  }
}

/// A receipt scanned on the device; it counts toward the receipt achievements. The receipt record is named when the image was kept.
public struct ReceiptScan: Sendable, Hashable {
  public let receiptId: UUID?

  public init(receiptId: UUID? = nil) {
    self.receiptId = receiptId
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    self.init(receiptId: try reader.optionalUUID("receiptId"))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("receiptId", receiptId)
  }
}

/// `money.noSpend`: the owner says nothing was spent on `date`, which covers that day's money logging as an expense would.
public struct NoSpendDay: Sendable, Hashable {
  public let date: LocalDate

  public init(date: LocalDate) {
    self.date = date
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    self.init(date: try reader.date("date"))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("date", date)
  }
}

/// `budget.closePeriod`: the verdict on the budget's period starting `periodStart`, and whether a savings deposit was written with it. Amounts stay in
/// the deposit record; a period over its limit or unscored deposits nothing.
public struct BudgetPeriodClose: Sendable, Hashable {
  public let budgetId: UUID
  public let periodStart: LocalDate
  public let outcome: BudgetCloseOutcome
  public let deposited: Bool

  public init(budgetId: UUID, periodStart: LocalDate, outcome: BudgetCloseOutcome, deposited: Bool) throws(CommandRefusal) {
    switch (outcome, deposited) {
    case (.over10, true), (.over25, true), (.overMore, true), (.unscored, true): throw .invalidField(field: "deposited", problem: .notAllowed)
    default: break
    }
    self.budgetId = budgetId
    self.periodStart = periodStart
    self.outcome = outcome
    self.deposited = deposited
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let budgetId = try reader.uuid("budgetId")
    let periodStart = try reader.date("periodStart")
    let outcome = try reader.choice("outcome", as: BudgetCloseOutcome.self)
    guard let deposited = reader.value("deposited")?.boolValue else { throw .invalidField(field: "deposited", problem: .notBoolean) }
    try self.init(budgetId: budgetId, periodStart: periodStart, outcome: outcome, deposited: deposited)
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("budgetId", budgetId)
    writer.put("periodStart", periodStart)
    writer.put("outcome", token: outcome)
    writer.put("deposited", deposited)
  }
}

/// `goal.milestone`: a savings goal's share reached a quarter, half, three quarters or all of its target.
public struct GoalMilestoneReached: Sendable, Hashable {
  public let goalId: UUID
  public let milestone: GoalMilestone

  public init(goalId: UUID, milestone: GoalMilestone) {
    self.goalId = goalId
    self.milestone = milestone
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let goalId = try reader.uuid("goalId")
    self.init(goalId: goalId, milestone: try reader.choice("milestone", as: GoalMilestone.self))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("goalId", goalId)
    writer.put("milestone", token: milestone)
  }
}

/// `goal.bought`: the goal's purchase, at or under its target (`within`) or above it.
public struct GoalPurchase: Sendable, Hashable {
  public let goalId: UUID
  public let outcome: GoalPurchaseOutcome

  public init(goalId: UUID, outcome: GoalPurchaseOutcome) {
    self.goalId = goalId
    self.outcome = outcome
  }

  init(reading reader: inout PayloadReader) throws(CommandRefusal) {
    let goalId = try reader.uuid("goalId")
    self.init(goalId: goalId, outcome: try reader.choice("outcome", as: GoalPurchaseOutcome.self))
  }

  func write(to writer: inout PayloadWriter) {
    writer.put("goalId", goalId)
    writer.put("outcome", token: outcome)
  }
}
