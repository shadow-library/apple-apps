import Foundation
import ShadowCore
import ShadowStore

/// A budget's span: a calendar month that renews, or a trip's own dates, counted once. Stored as one field so a trip's dates stay a valid pair under merge.
public enum BudgetPeriodKind: Hashable, Sendable, StoredValue {
  case monthly
  case trip(from: LocalDate, through: LocalDate)

  private enum Kind: String {
    case monthly
    case trip
  }

  public init?(stored: JSONValue) {
    guard
      let period = MemberReader<BudgetPeriodMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) -> BudgetPeriodKind in
          let name: String = try reader.required(.kind)
          let from: LocalDate? = try reader.optional(.from)
          let through: LocalDate? = try reader.optional(.through)
          switch (Kind(rawValue: name), from, through) {
          case (.monthly, nil, nil): return .monthly
          case (.trip, let from?, let through?) where from <= through: return .trip(from: from, through: through)
          default: throw .invalid(field: BudgetPeriodMember.kind.rawValue)
          }
        })
    else { return nil }
    self = period
  }

  public var stored: JSONValue {
    var members = RecordMembers<BudgetPeriodMember>()
    switch self {
    case .monthly:
      members.put(.kind, Kind.monthly.rawValue)
    case .trip(let from, let through):
      members.put(.kind, Kind.trip.rawValue)
      members.put(.from, from)
      members.put(.through, through)
    }
    return members.json
  }
}

/// An amount that takes effect from a later day, kept with that day in one field so a merge never leaves an amount without its day.
public struct StagedAmount: Hashable, Sendable, StoredValue {
  public let amountMinor: Int64
  public let from: LocalDate

  public init(amountMinor: Int64, from: LocalDate) {
    self.amountMinor = amountMinor
    self.from = from
  }

  public init?(stored: JSONValue) {
    guard
      let staged = MemberReader<StagedAmountMember>.nested(
        stored, { reader throws(MemoirUnreadable) in StagedAmount(amountMinor: try reader.required(.amountMinor), from: try reader.required(.from)) })
    else { return nil }
    self = staged
  }

  public var stored: JSONValue {
    var members = RecordMembers<StagedAmountMember>()
    members.put(.amountMinor, amountMinor)
    members.put(.from, from)
    return members.json
  }
}

/// A named spending limit in its own currency. The currency and the day it was created are written once; the name, the limit, a raise staged for a
/// later period and the owner's one-off threshold are registers. The name and the limit may be absent, so a device that only makes sure Home exists
/// writes no register that could undo a limit another device set.
public struct BudgetRecord: IdentifiedRecord, RemovableMemoirRecord, Hashable {
  public static let kind = MemoirKind.budget
  public static let homeIDDomain = "com.shadow.library.memoircore.home-budget"
  public static let homeID = derivedID(homeIDDomain, "home")

  public let id: UUID
  public var name: String?
  public var currency: CurrencyCode
  public var limitMinor: Int64?
  public var period: BudgetPeriodKind
  public var stagedLimit: StagedAmount?
  public var oneOffFromMinor: Int64?
  public var stagedOneOff: StagedAmount?
  public var createdOn: LocalDate

  public init(
    id: UUID, name: String? = nil, currency: CurrencyCode, limitMinor: Int64? = nil, period: BudgetPeriodKind, stagedLimit: StagedAmount? = nil, oneOffFromMinor: Int64? = nil,
    stagedOneOff: StagedAmount? = nil, createdOn: LocalDate
  ) {
    self.id = id
    self.name = name
    self.currency = currency
    self.limitMinor = limitMinor
    self.period = period
    self.stagedLimit = stagedLimit
    self.oneOffFromMinor = oneOffFromMinor
    self.stagedOneOff = stagedOneOff
    self.createdOn = createdOn
  }

  public init(id: UUID, reading reader: MemberReader<BudgetField>) throws(MemoirUnreadable) {
    self.init(
      id: id, name: try reader.optional(.name), currency: try reader.required(.currency), limitMinor: try reader.optional(.limitMinor),
      period: try reader.required(.period), stagedLimit: try reader.optional(.stagedLimit), oneOffFromMinor: try reader.optional(.oneOffFromMinor),
      stagedOneOff: try reader.optional(.stagedOneOff), createdOn: try reader.required(.createdOn))
  }

  public var isHome: Bool { id == Self.homeID }

  public var members: RecordMembers<BudgetField> {
    var members = RecordMembers<BudgetField>()
    members.put(.name, name)
    members.put(.currency, currency)
    members.put(.limitMinor, limitMinor)
    members.put(.period, period)
    members.put(.stagedLimit, stagedLimit)
    members.put(.oneOffFromMinor, oneOffFromMinor)
    members.put(.stagedOneOff, stagedOneOff)
    members.put(.createdOn, createdOn)
    return members
  }
}

/// What a budget's close put into savings, in the home currency (zero when it put nothing in), with the rate a foreign budget converted at, the close
/// command it was written with, and the period's spending, limit and median single expense (nil without a positive one) in the budget's currency as the
/// close judged them, which every later read of the period takes instead of the expenses as they stand.
public struct SavingsDeposit: Hashable, Sendable, StoredValue {
  public let amountMinor: Int64
  public let currency: CurrencyCode
  /// The price of one unit of the budget's currency in home that converted the deposit: the newest recorded on or before `closedOn`; nil for a budget in
  /// the home currency or a close that deposited nothing.
  public let rate: DecimalText?
  public let closedOn: LocalDate
  public let command: UUID
  public let spentMinor: Int64
  public let limitMinor: Int64?
  public let medianExpenseMinor: Int64?

  public init(
    amountMinor: Int64, currency: CurrencyCode, rate: DecimalText? = nil, closedOn: LocalDate, command: UUID, spentMinor: Int64, limitMinor: Int64?,
    medianExpenseMinor: Int64?
  ) {
    self.amountMinor = amountMinor
    self.currency = currency
    self.rate = rate
    self.closedOn = closedOn
    self.command = command
    self.spentMinor = spentMinor
    self.limitMinor = limitMinor
    self.medianExpenseMinor = medianExpenseMinor
  }

  public init?(stored: JSONValue) {
    guard
      let deposit = MemberReader<SavingsDepositMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) in
          SavingsDeposit(
            amountMinor: try reader.required(.amountMinor), currency: try reader.required(.currency), rate: try reader.optional(.rate),
            closedOn: try reader.required(.closedOn), command: try reader.required(.command), spentMinor: try reader.required(.spentMinor),
            limitMinor: try reader.optional(.limitMinor), medianExpenseMinor: try reader.optional(.medianExpenseMinor))
        })
    else { return nil }
    self = deposit
  }

  public var stored: JSONValue {
    var members = RecordMembers<SavingsDepositMember>()
    members.put(.amountMinor, amountMinor)
    members.put(.currency, currency)
    members.put(.rate, rate)
    members.put(.closedOn, closedOn)
    members.put(.command, command)
    members.put(.spentMinor, spentMinor)
    members.put(.limitMinor, limitMinor)
    members.put(.medianExpenseMinor, medianExpenseMinor)
    return members.json
  }
}

/// One deposit per budget and period, keyed by both. The whole deposit is one first-writer field, so the first close to be recorded is final on every
/// device and no later writer can fill in a member the first one left out.
public struct SavingsDepositRecord: NaturalKeyRecord {
  public static let kind = MemoirKind.savingsDeposit

  public let budget: UUID
  public let periodStart: LocalDate
  public let deposit: SavingsDeposit

  public init(budget: UUID, periodStart: LocalDate, deposit: SavingsDeposit) {
    self.budget = budget
    self.periodStart = periodStart
    self.deposit = deposit
  }

  public init(key: MemoirKey, reading reader: MemberReader<SavingsDepositField>) throws(MemoirUnreadable) {
    guard case .savingsDeposit(let budget, let periodStart) = key else { throw .identity(key.ref) }
    self.init(budget: budget, periodStart: periodStart, deposit: try reader.required(.deposit))
  }

  public var key: MemoirKey { .savingsDeposit(budget: budget, periodStart: periodStart) }

  public var members: RecordMembers<SavingsDepositField> {
    var members = RecordMembers<SavingsDepositField>()
    members.put(.deposit, deposit)
    return members
  }
}

public enum SavingsGoalState: String, CaseIterable, Hashable, Sendable {
  case active
  case bought
  case abandoned
}

/// A goal's place in the fill order, as a fractional index: ranks compare by their bytes, and a rank can always be made between any two, so moving a goal
/// rewrites only that goal's rank and two devices reordering at once both keep their move. Digits are `0-9A-Za-z` and the last is never `0`, which
/// keeps room below every rank. Two goals given the same rank on two devices are ordered by id.
public struct SavingsGoalRank: Hashable, Sendable, Comparable, StoredValue, CustomStringConvertible {
  public static let maximumLength = 64

  public let text: String

  public init?(_ text: String) {
    let bytes = Array(text.utf8)
    guard (1...Self.maximumLength).contains(bytes.count), bytes.allSatisfy(Self.isDigit), bytes.last != UInt8(ascii: "0") else { return nil }
    self.text = text
  }

  public init?(stored: JSONValue) {
    guard let text = stored.stringValue else { return nil }
    self.init(text)
  }

  public var stored: JSONValue { .string(text) }

  public var description: String { text }

  public static func < (lhs: SavingsGoalRank, rhs: SavingsGoalRank) -> Bool {
    lhs.text.utf8.lexicographicallyPrecedes(rhs.text.utf8)
  }

  private static func isDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
  }
}

/// Something the owner saves towards, in the home currency, which is written once with the day the goal was created.
public struct SavingsGoalRecord: IdentifiedRecord, RemovableMemoirRecord, Hashable {
  public static let kind = MemoirKind.savingsGoal

  public let id: UUID
  public var name: String
  public var symbol: String
  public var targetMinor: Int64
  public var currency: CurrencyCode
  public var targetDate: LocalDate?
  public var rank: SavingsGoalRank
  public var createdOn: LocalDate
  public var state: StoredChoice<SavingsGoalState>

  public init(
    id: UUID, name: String, symbol: String, targetMinor: Int64, currency: CurrencyCode, targetDate: LocalDate? = nil, rank: SavingsGoalRank, createdOn: LocalDate,
    state: StoredChoice<SavingsGoalState> = .known(.active)
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.targetMinor = targetMinor
    self.currency = currency
    self.targetDate = targetDate
    self.rank = rank
    self.createdOn = createdOn
    self.state = state
  }

  public init(id: UUID, reading reader: MemberReader<SavingsGoalField>) throws(MemoirUnreadable) {
    self.init(
      id: id, name: try reader.required(.name), symbol: try reader.required(.symbol), targetMinor: try reader.required(.targetMinor),
      currency: try reader.required(.currency), targetDate: try reader.optional(.targetDate), rank: try reader.required(.rank), createdOn: try reader.required(.createdOn),
      state: try reader.required(.state))
  }

  public var members: RecordMembers<SavingsGoalField> {
    var members = RecordMembers<SavingsGoalField>()
    members.put(.name, name)
    members.put(.symbol, symbol)
    members.put(.targetMinor, targetMinor)
    members.put(.currency, currency)
    members.put(.targetDate, targetDate)
    members.put(.rank, rank)
    members.put(.createdOn, createdOn)
    members.put(.state, state)
    return members
  }
}
