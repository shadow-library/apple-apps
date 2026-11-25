import Foundation
import ShadowStore

/// A budget that counts: a readable one not deleted, or Home, which cannot be deleted. Amounts are read with any staged change whose day has come, and
/// clamped at zero, since a merge can combine values no single write made.
public struct LiveBudget: Hashable, Sendable, Identifiable {
  public let record: BudgetRecord
  let accountLimitMinor: Int64?

  init(record: BudgetRecord, settings: AccountSettingsRecord?) {
    self.record = record
    accountLimitMinor = record.isHome ? HomeBudget.accountLimitMinor(settings, currency: record.currency) : nil
  }

  public var id: UUID { record.id }
  public var isHome: Bool { record.isHome }
  public var currency: CurrencyCode { record.currency }

  public func limitMinor(on date: LocalDate) -> Int64? {
    limitStaging.value(on: date).map { max(0, $0) }
  }

  /// The limit a period is measured against: the one in force on its last day.
  public func limitMinor(for period: BudgetPeriod) -> Int64? {
    limitMinor(on: period.end)
  }

  public func pendingLimit(on date: LocalDate) -> StagedAmount? {
    limitStaging.pending(on: date)
  }

  public func oneOffFromMinor(on date: LocalDate) -> Int64? {
    oneOffStaging.value(on: date).map { max(0, $0) }
  }

  public func pendingOneOff(on date: LocalDate) -> StagedAmount? {
    oneOffStaging.pending(on: date)
  }

  public func period(containing date: LocalDate) -> BudgetPeriod? {
    BudgetPeriod.containing(date, of: record.period)
  }

  public func covers(_ date: LocalDate) -> Bool {
    period(containing: date) != nil
  }

  var limitStaging: BudgetStaging { BudgetStaging(base: record.limitMinor ?? accountLimitMinor, staged: record.stagedLimit) }
  var oneOffStaging: BudgetStaging { BudgetStaging(base: record.oneOffFromMinor, staged: record.stagedOneOff) }
}

/// The vault's live budgets, Home first and then by the day each was created. Home is listed once `HomeBudget.ensure` has written it; until then
/// `homeCurrency` is the account's default currency.
public struct Budgets: Equatable, Sendable {
  public let live: [LiveBudget]
  public let homeCurrency: CurrencyCode?
  public let unreadable: Int

  public init(_ listing: MemoirListing<MemoirEntry<BudgetRecord>>, settings: AccountSettingsRecord?) {
    live = listing.entries.filter { !$0.isRemoved || $0.record.isHome }.map { LiveBudget(record: $0.record, settings: settings) }.sorted(by: Self.precedes)
    homeCurrency = live.first(where: \.isHome)?.currency ?? settings?.defaultCurrency
    unreadable = listing.unreadable
  }

  public static func live<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(FinanceError) -> Budgets {
    let listing: MemoirListing<MemoirEntry<BudgetRecord>>
    do throws(StoreError) {
      listing = try BudgetRecord.listing(in: source)
    } catch {
      throw FinanceError(error)
    }
    return Budgets(listing, settings: try FinanceLedger.settings(in: source))
  }

  public var home: LiveBudget? { live.first(where: \.isHome) }

  public func budget(_ id: UUID) -> LiveBudget? {
    live.first { $0.id == id }
  }

  /// Two devices can each create a trip or a monthly budget the other's would refuse; every device then picks the same one: Home, then the budget
  /// created first, then the lower id.
  static func precedes(_ first: LiveBudget, _ second: LiveBudget) -> Bool {
    if first.isHome != second.isHome { return first.isHome }
    if first.record.createdOn != second.record.createdOn { return first.record.createdOn < second.record.createdOn }
    return first.id.uuidString < second.id.uuidString
  }
}
