import Foundation
import ShadowCore
import ShadowStore

public struct MoneyAmount: Hashable, Sendable, StoredValue {
  public let amountMinor: Int64
  public let currency: CurrencyCode

  public init(amountMinor: Int64, currency: CurrencyCode) {
    self.amountMinor = amountMinor
    self.currency = currency
  }

  public init?(stored: JSONValue) {
    guard
      let amount = MemberReader<MoneyMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) in
          MoneyAmount(amountMinor: try reader.required(.amountMinor), currency: try reader.required(.currency))
        })
    else { return nil }
    self = amount
  }

  public var stored: JSONValue {
    var members = RecordMembers<MoneyMember>()
    members.put(.amountMinor, amountMinor)
    members.put(.currency, currency)
    return members.json
  }
}

/// The rate an expense was converted at, with the date it is for and the currency it converts into; written once, in one field, and never changed.
public struct ExpenseRate: Hashable, Sendable, StoredValue {
  public let rate: DecimalText
  public let date: LocalDate
  public let quote: CurrencyCode

  public init(rate: DecimalText, date: LocalDate, quote: CurrencyCode) {
    self.rate = rate
    self.date = date
    self.quote = quote
  }

  public init?(stored: JSONValue) {
    guard
      let rate = MemberReader<ExpenseRateMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) in
          ExpenseRate(rate: try reader.required(.rate), date: try reader.required(.date), quote: try reader.required(.quote))
        })
    else { return nil }
    self = rate
  }

  public var stored: JSONValue {
    var members = RecordMembers<ExpenseRateMember>()
    members.put(.rate, rate)
    members.put(.date, date)
    members.put(.quote, quote)
    return members.json
  }
}

/// A rate the owner typed for one expense, into the currency it names. It converts that expense ahead of any recorded or locked rate, applies to no other
/// expense, and can be changed or cleared, so it is kept apart from the locked rate, which is written once.
public struct ManualRate: Hashable, Sendable, StoredValue {
  public let rate: DecimalText
  public let quote: CurrencyCode

  public init(rate: DecimalText, quote: CurrencyCode) {
    self.rate = rate
    self.quote = quote
  }

  public init?(stored: JSONValue) {
    guard
      let rate = MemberReader<ManualRateMember>.nested(
        stored, { reader throws(MemoirUnreadable) in ManualRate(rate: try reader.required(.rate), quote: try reader.required(.quote)) })
    else { return nil }
    self = rate
  }

  public var stored: JSONValue {
    var members = RecordMembers<ManualRateMember>()
    members.put(.rate, rate)
    members.put(.quote, quote)
    return members.json
  }
}

/// The values a subscription cycle's expense was first written with, and the subscription that wrote it, kept whole in one first-writer field so every
/// device seeds the expense alike. It holds none of the owner's words: a first-writer value outlives the expense's deletion.
public struct ExpenseCycleSeed: Hashable, Sendable, StoredValue {
  public let subscription: UUID
  public let amountMinor: Int64
  public let occurredOn: LocalDate
  public let category: CategoryKey

  public init(subscription: UUID, amountMinor: Int64, occurredOn: LocalDate, category: CategoryKey) {
    self.subscription = subscription
    self.amountMinor = amountMinor
    self.occurredOn = occurredOn
    self.category = category
  }

  public init?(stored: JSONValue) {
    guard
      let seed = MemberReader<ExpenseCycleMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) in
          ExpenseCycleSeed(
            subscription: try reader.required(.subscription), amountMinor: try reader.required(.amountMinor), occurredOn: try reader.required(.occurredOn),
            category: try reader.required(.category))
        })
    else { return nil }
    self = seed
  }

  public var stored: JSONValue {
    var members = RecordMembers<ExpenseCycleMember>()
    members.put(.subscription, subscription)
    members.put(.amountMinor, amountMinor)
    members.put(.occurredOn, occurredOn)
    members.put(.category, category)
    return members.json
  }
}

/// `budget` overrides the budget the expense is counted in, `fromSavingsMinor` is the part paid from savings in the expense's currency and `goal` the
/// savings goal it buys.
public struct ExpenseRecord: IdentifiedRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.expense

  public let id: UUID
  public var amountMinor: Int64
  public var currency: CurrencyCode
  public var occurredOn: LocalDate
  public var category: CategoryKey
  public var merchant: String?
  public var note: String?
  public var receipt: UUID?
  public var rate: ExpenseRate?
  public var manualRate: ManualRate?
  public var budget: UUID?
  public var fromSavingsMinor: Int64?
  public var goal: UUID?
  public var cycle: ExpenseCycleSeed?
  public var loggedAtMillis: Int64

  public init(
    id: UUID, amountMinor: Int64, currency: CurrencyCode, occurredOn: LocalDate, category: CategoryKey, merchant: String? = nil, note: String? = nil, receipt: UUID? = nil,
    rate: ExpenseRate? = nil, manualRate: ManualRate? = nil, budget: UUID? = nil, fromSavingsMinor: Int64? = nil, goal: UUID? = nil, cycle: ExpenseCycleSeed? = nil,
    loggedAtMillis: Int64
  ) {
    self.id = id
    self.amountMinor = amountMinor
    self.currency = currency
    self.occurredOn = occurredOn
    self.category = category
    self.merchant = merchant
    self.note = note
    self.receipt = receipt
    self.rate = rate
    self.manualRate = manualRate
    self.budget = budget
    self.fromSavingsMinor = fromSavingsMinor
    self.goal = goal
    self.cycle = cycle
    self.loggedAtMillis = loggedAtMillis
  }

  /// A cycle's expense is written with its seed alone, so the amount, date and category follow the seed until an edit writes them.
  public init(id: UUID, reading reader: MemberReader<ExpenseField>) throws(MemoirUnreadable) {
    let cycle: ExpenseCycleSeed? = try reader.optional(.cycle)
    self.init(
      id: id, amountMinor: try reader.required(.amountMinor, seed: cycle?.amountMinor), currency: try reader.required(.currency),
      occurredOn: try reader.required(.occurredOn, seed: cycle?.occurredOn), category: try reader.required(.category, seed: cycle?.category),
      merchant: try reader.optional(.merchant), note: try reader.optional(.note), receipt: try reader.optional(.receipt),
      rate: try reader.optional(.rate), manualRate: try reader.optional(.manualRate), budget: try reader.optional(.budget),
      fromSavingsMinor: try reader.optional(.fromSavingsMinor), goal: try reader.optional(.goal), cycle: cycle, loggedAtMillis: try reader.required(.loggedAtMillis))
  }

  public var members: RecordMembers<ExpenseField> {
    var members = RecordMembers<ExpenseField>()
    members.put(.amountMinor, amountMinor)
    members.put(.currency, currency)
    members.put(.occurredOn, occurredOn)
    members.put(.category, category)
    members.put(.merchant, merchant)
    members.put(.note, note)
    members.put(.receipt, receipt)
    members.put(.rate, rate)
    members.put(.manualRate, manualRate)
    members.put(.budget, budget)
    members.put(.fromSavingsMinor, fromSavingsMinor)
    members.put(.goal, goal)
    members.put(.cycle, cycle)
    members.put(.loggedAtMillis, loggedAtMillis)
    return members
  }
}

public enum SubscriptionFrequency: String, CaseIterable, Hashable, Sendable {
  case weekly
  case monthly
  case quarterly
  case yearly
  case custom
}

public enum SubscriptionReminderLead: String, CaseIterable, Hashable, Sendable {
  case onDay = "on_day"
  case oneDay = "1_day"
  case twoDays = "2_day"
  case threeDays = "3_day"
  case oneWeek = "1_week"
}

/// `anchorOn` is the due date the owner set; the next due and last confirmed cycles are derived from confirm-cycle commands, which also grant the coin.
/// `budget` overrides the budget every cycle's expense is counted in.
public struct SubscriptionRecord: IdentifiedRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.subscription

  public let id: UUID
  public var name: String
  public var note: String?
  public var amountMinor: Int64
  public var currency: CurrencyCode
  public var frequency: StoredChoice<SubscriptionFrequency>
  public var customIntervalDays: Int?
  public var billingDay: Int
  public var anchorOn: LocalDate
  public var category: CategoryKey
  public var reminderEnabled: Bool
  public var reminderLead: StoredChoice<SubscriptionReminderLead>
  public var active: Bool
  public var budget: UUID?

  public init(
    id: UUID, name: String, note: String? = nil, amountMinor: Int64, currency: CurrencyCode, frequency: StoredChoice<SubscriptionFrequency>, customIntervalDays: Int? = nil,
    billingDay: Int, anchorOn: LocalDate, category: CategoryKey, reminderEnabled: Bool = false,
    reminderLead: StoredChoice<SubscriptionReminderLead> = .known(.onDay), active: Bool = true, budget: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.note = note
    self.amountMinor = amountMinor
    self.currency = currency
    self.frequency = frequency
    self.customIntervalDays = customIntervalDays
    self.billingDay = billingDay
    self.anchorOn = anchorOn
    self.category = category
    self.reminderEnabled = reminderEnabled
    self.reminderLead = reminderLead
    self.active = active
    self.budget = budget
  }

  public init(id: UUID, reading reader: MemberReader<SubscriptionField>) throws(MemoirUnreadable) {
    self.init(
      id: id, name: try reader.required(.name), note: try reader.optional(.note), amountMinor: try reader.required(.amountMinor), currency: try reader.required(.currency),
      frequency: try reader.required(.frequency), customIntervalDays: try reader.optional(.customIntervalDays), billingDay: try reader.required(.billingDay),
      anchorOn: try reader.required(.anchorOn), category: try reader.required(.category),
      reminderEnabled: try reader.required(.reminderEnabled), reminderLead: try reader.required(.reminderLead), active: try reader.required(.active),
      budget: try reader.optional(.budget))
  }

  public var members: RecordMembers<SubscriptionField> {
    var members = RecordMembers<SubscriptionField>()
    members.put(.name, name)
    members.put(.note, note)
    members.put(.amountMinor, amountMinor)
    members.put(.currency, currency)
    members.put(.frequency, frequency)
    members.put(.customIntervalDays, customIntervalDays)
    members.put(.billingDay, billingDay)
    members.put(.anchorOn, anchorOn)
    members.put(.category, category)
    members.put(.reminderEnabled, reminderEnabled)
    members.put(.reminderLead, reminderLead)
    members.put(.active, active)
    members.put(.budget, budget)
    return members
  }
}

/// Keyed by its category key, so two devices seeding the same built-in category create one record. `essential` is the owner's choice, nil until made. A
/// record written without `archived` (`CategoryEdits.setEssential` on a category this device had no record of) reads as unarchived.
public struct ExpenseCategoryRecord: NaturalKeyRecord {
  public static let kind = MemoirKind.expenseCategory

  public let categoryKey: CategoryKey
  public var label: String
  public var archived: Bool
  public var essential: Bool?

  public init(key: CategoryKey, label: String, archived: Bool = false, essential: Bool? = nil) {
    categoryKey = key
    self.label = label
    self.archived = archived
    self.essential = essential
  }

  public init(key: MemoirKey, reading reader: MemberReader<ExpenseCategoryField>) throws(MemoirUnreadable) {
    guard case .expenseCategory(let categoryKey) = key else { throw .identity(key.ref) }
    self.init(key: categoryKey, label: try reader.required(.label), archived: try reader.optional(.archived) ?? false, essential: try reader.optional(.essential))
  }

  public var key: MemoirKey { .expenseCategory(categoryKey) }

  public var members: RecordMembers<ExpenseCategoryField> {
    var members = RecordMembers<ExpenseCategoryField>()
    members.put(.label, label)
    members.put(.archived, archived)
    members.put(.essential, essential)
    return members
  }
}

/// A reference to the receipt image's blob; the image itself syncs as a blob, never inside the record.
public struct ReceiptRecord: IdentifiedRecord, RemovableMemoirRecord {
  public static let kind = MemoirKind.receipt

  public let id: UUID
  public let blob: BlobName
  public let contentType: String
  public let byteCount: Int

  public init(id: UUID, blob: BlobName, contentType: String, byteCount: Int) {
    self.id = id
    self.blob = blob
    self.contentType = contentType
    self.byteCount = byteCount
  }

  public init(id: UUID, reading reader: MemberReader<ReceiptField>) throws(MemoirUnreadable) {
    self.init(id: id, blob: try reader.required(.blob), contentType: try reader.required(.contentType), byteCount: try reader.required(.byteCount))
  }

  public var members: RecordMembers<ReceiptField> {
    var members = RecordMembers<ReceiptField>()
    members.put(.blob, blob)
    members.put(.contentType, contentType)
    members.put(.byteCount, byteCount)
    return members
  }

  /// Purged rather than removed: a removed record keeps its fields, and with them the name that keeps the blob, while a purge releases it. A receipt id
  /// is never written again, so the purge blocks nothing; one not yet synced here is purged ahead of its arrival.
  static func purge(_ id: UUID, in transaction: inout WriteTransaction) throws(MemoirRecordError) {
    do throws(StoreError) {
      _ = try transaction.purge(ref(id))
    } catch {
      throw .store(error)
    }
  }
}

/// One rate per pair and day; the first device to record it wins, so every device converts with the same number.
public struct FxRateRecord: NaturalKeyRecord {
  public static let kind = MemoirKind.fxRate

  public let base: CurrencyCode
  public let quote: CurrencyCode
  public let date: LocalDate
  public let rate: DecimalText

  public init(base: CurrencyCode, quote: CurrencyCode, date: LocalDate, rate: DecimalText) {
    self.base = base
    self.quote = quote
    self.date = date
    self.rate = rate
  }

  public init(key: MemoirKey, reading reader: MemberReader<FxRateField>) throws(MemoirUnreadable) {
    guard case .fxRate(let base, let quote, let date) = key else { throw .identity(key.ref) }
    self.init(base: base, quote: quote, date: date, rate: try reader.required(.rate))
  }

  public var key: MemoirKey { .fxRate(base: base, quote: quote, date: date) }

  public var members: RecordMembers<FxRateField> {
    var members = RecordMembers<FxRateField>()
    members.put(.rate, rate)
    return members
  }
}

/// The owner's day: `start` is the first minute of the day, `end` the minute they go to sleep. Stored as one field so the pair stays valid under merge.
/// apps/memoir-server/src/modules/account/sleep-window.ts:3-14: the sleep from `end` round to `start` lasts 3 to 14 hours.
public struct ScheduleWindow: Hashable, Sendable, StoredValue {
  public static let minimumSleepMinutes = 3 * 60
  public static let maximumSleepMinutes = 14 * 60
  public static let standard = ScheduleWindow(validated: 360, 1380)

  private static let minutesPerDay = 1440

  public let start: Int
  public let end: Int

  public init?(start: Int, end: Int) {
    guard (0..<Self.minutesPerDay).contains(start), (0..<Self.minutesPerDay).contains(end) else { return nil }
    let sleep = ((start - end) % Self.minutesPerDay + Self.minutesPerDay) % Self.minutesPerDay
    guard (Self.minimumSleepMinutes...Self.maximumSleepMinutes).contains(sleep) else { return nil }
    self.start = start
    self.end = end
  }

  private init(validated start: Int, _ end: Int) {
    self.start = start
    self.end = end
  }

  public init?(stored: JSONValue) {
    guard
      let pair = MemberReader<ScheduleMember>.nested(stored, { reader throws(MemoirUnreadable) -> (Int, Int) in (try reader.required(.start), try reader.required(.end)) }),
      let window = ScheduleWindow(start: pair.0, end: pair.1)
    else { return nil }
    self = window
  }

  public var stored: JSONValue {
    var members = RecordMembers<ScheduleMember>()
    members.put(.start, start)
    members.put(.end, end)
    return members.json
  }
}

/// The vault's single settings record. The time zone, intensity mode and returner threshold feed replay, so they are commands instead. Each module is
/// its own register, nil meaning on, so two devices turning different modules on or off both keep their change; `moneyScoredFrom` is written once.
public struct AccountSettingsRecord: NaturalKeyRecord {
  public static let kind = MemoirKind.accountSettings

  public var defaultCurrency: CurrencyCode
  public var enabledCurrencies: [CurrencyCode]
  public var monthlyBudget: MoneyAmount?
  public var schedule: ScheduleWindow
  public var weekStart: Int
  public var moduleHero: Bool?
  public var moduleQuests: Bool?
  public var moduleMoney: Bool?
  public var moduleJournal: Bool?
  public var moduleMeals: Bool?
  public var moduleBody: Bool?
  public var moneyScoredFrom: LocalDate?

  public init(
    defaultCurrency: CurrencyCode, enabledCurrencies: [CurrencyCode], monthlyBudget: MoneyAmount? = nil, schedule: ScheduleWindow = .standard,
    weekStart: Int = 1, moduleHero: Bool? = nil, moduleQuests: Bool? = nil, moduleMoney: Bool? = nil, moduleJournal: Bool? = nil, moduleMeals: Bool? = nil,
    moduleBody: Bool? = nil, moneyScoredFrom: LocalDate? = nil
  ) {
    self.defaultCurrency = defaultCurrency
    self.enabledCurrencies = enabledCurrencies
    self.monthlyBudget = monthlyBudget
    self.schedule = schedule
    self.weekStart = weekStart
    self.moduleHero = moduleHero
    self.moduleQuests = moduleQuests
    self.moduleMoney = moduleMoney
    self.moduleJournal = moduleJournal
    self.moduleMeals = moduleMeals
    self.moduleBody = moduleBody
    self.moneyScoredFrom = moneyScoredFrom
  }

  public init(key: MemoirKey, reading reader: MemberReader<AccountSettingsField>) throws(MemoirUnreadable) {
    guard case .accountSettings = key else { throw .identity(key.ref) }
    self.init(
      defaultCurrency: try reader.required(.defaultCurrency), enabledCurrencies: try reader.required(.enabledCurrencies), monthlyBudget: try reader.optional(.monthlyBudget),
      schedule: try reader.required(.schedule), weekStart: try reader.required(.weekStart), moduleHero: try reader.optional(.moduleHero),
      moduleQuests: try reader.optional(.moduleQuests), moduleMoney: try reader.optional(.moduleMoney), moduleJournal: try reader.optional(.moduleJournal),
      moduleMeals: try reader.optional(.moduleMeals), moduleBody: try reader.optional(.moduleBody), moneyScoredFrom: try reader.optional(.moneyScoredFrom))
  }

  public var key: MemoirKey { .accountSettings }

  public var members: RecordMembers<AccountSettingsField> {
    var members = RecordMembers<AccountSettingsField>()
    members.put(.defaultCurrency, defaultCurrency)
    members.put(.enabledCurrencies, enabledCurrencies)
    members.put(.monthlyBudget, monthlyBudget)
    members.put(.schedule, schedule)
    members.put(.weekStart, weekStart)
    members.put(.moduleHero, moduleHero)
    members.put(.moduleQuests, moduleQuests)
    members.put(.moduleMoney, moduleMoney)
    members.put(.moduleJournal, moduleJournal)
    members.put(.moduleMeals, moduleMeals)
    members.put(.moduleBody, moduleBody)
    members.put(.moneyScoredFrom, moneyScoredFrom)
    return members
  }
}
