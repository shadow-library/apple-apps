import Foundation
import ShadowCore
import ShadowStore

public enum ModuleChangeError: ShadowError {
  case settingsAbsent
  case refused(ModuleSelectionError)
  case store(StoreError)
  case record(MemoirRecordError)
  case issue(CommandIssueError)
  case clock(CalendarError)

  public var code: String {
    switch self {
    case .settingsAbsent: "memoir_modules.settings_absent"
    case .refused(let refusal): refusal.code
    case .store(let error): error.code
    case .record(let error): error.code
    case .issue(let error): error.code
    case .clock(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .settingsAbsent: "Modules are chosen once the home currency is set."
    case .refused(let refusal): refusal.errorDescription
    case .store(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .issue(let error): error.errorDescription
    case .clock(let error): error.errorDescription
    }
  }

  init(_ error: StoreError) {
    switch error {
    case .aborted(let inner as ModuleChangeError): self = inner
    case .aborted(let inner as ModuleSelectionError): self = .refused(inner)
    case .aborted(let inner as MemoirRecordError): self = .record(inner)
    case .aborted(let inner as CommandIssueError): self = .issue(inner)
    case .aborted(let inner as CommandRefusal): self = .issue(.refused(inner))
    case .aborted(let inner as CalendarError): self = .clock(inner)
    case .aborted(let inner as StoreError): self = .store(inner)
    default: self = .store(error)
    }
  }
}

/// What one module change does, or would do: the selection before and after, the quests it pauses, the day money starts to be scored from when this
/// change sets it, the Health reader it clears and whether Activity leaves iCloud, after which the app reroutes sync.
public struct ModuleChange: Sendable, Equatable {
  public let before: ModuleSelection
  public let after: ModuleSelection
  public let pausedQuests: [UUID]
  public let moneyScoredFrom: LocalDate?
  public let clearedReader: HealthReaderDesignation?
  public let activityLeavesICloud: Bool

  public var turnedOn: Set<MemoirModule> { after.modules.subtracting(before.modules) }
  public var turnedOff: Set<MemoirModule> { before.modules.subtracting(after.modules) }
}

/// The only writer of the settings record's module fields, in one main-store write. A change names only the modules the owner turned on or off and is
/// applied to the selection as the write reads it, so a change made meanwhile on another device to another module survives; besides those modules, only
/// the fields of a merge that read as a nearer valid selection are written, back to what it reads as.
///
/// While Quests is off every quest replay holds active is paused (`quest.update` with `active` false); turning Quests on reactivates nothing. While Body
/// is off the Health reader is cleared, whichever device holds it, and Activity stays off iCloud. `enforce` applies both to what arrived from a device
/// that had not yet seen the change. Turning Hero and Money on together for the first time sets `moneyScoredFrom` to the account's day, once. Quests are
/// those of the projection as the last commit left it, so after a replay halt the quests of commands past it are not seen.
public struct ModuleChanges: Sendable {
  public let stores: MemoirStores
  public let issuer: CommandIssuerSource
  /// The trusted wall clock the issuer stamps with, for the account's day.
  public let now: @Sendable () -> Date

  public init(stores: MemoirStores, issuer: CommandIssuerSource, now: @escaping @Sendable () -> Date) {
    self.stores = stores
    self.issuer = issuer
    self.now = now
  }

  /// What `apply` would do as the vault now stands, writing nothing, so the owner can be asked before quests are paused.
  public func preview(_ module: MemoirModule, enabled: Bool) async throws(ModuleChangeError) -> ModuleChange {
    try await preview([module: enabled])
  }

  public func preview(_ changes: [MemoirModule: Bool]) async throws(ModuleChangeError) -> ModuleChange {
    let source = issuer
    let now = now
    return try await call { () async throws(StoreError) in
      try await stores.main.read { transaction in try Self.plan(.change(changes), in: transaction, issuer: source, now: now).change }
    }
  }

  @discardableResult
  public func apply(_ module: MemoirModule, enabled: Bool) async throws(ModuleChangeError) -> ModuleChange {
    try await apply([module: enabled])
  }

  /// Several modules at once, for a step no single module makes valid, such as turning Hero and Quests on beside Journal alone.
  @discardableResult
  public func apply(_ changes: [MemoirModule: Bool]) async throws(ModuleChangeError) -> ModuleChange {
    try await write(.change(changes))
  }

  /// Pauses the quests that are active while Quests is off and clears a Health reader or Activity on iCloud while Body is off; nil, writing nothing,
  /// when nothing needs it or the vault has no settings yet.
  @discardableResult
  public func enforce() async throws(ModuleChangeError) -> ModuleChange? {
    let source = issuer
    let now = now
    let needed = try await call { () async throws(StoreError) in
      try await stores.main.read { transaction in try Self.plan(.enforce, in: transaction, issuer: source, now: now).needsWrite }
    }
    guard needed else { return nil }
    let change = try await write(.enforce)
    return change.pausedQuests.isEmpty && change.clearedReader == nil && !change.activityLeavesICloud ? nil : change
  }

  private enum Request {
    case change([MemoirModule: Bool])
    case enforce
  }

  private struct Plan {
    let change: ModuleChange
    let settings: AccountSettingsRecord?
    let fields: [MemoirModule: Bool]
    let issuer: CommandIssuer?

    var needsWrite: Bool {
      !fields.isEmpty || !change.pausedQuests.isEmpty || change.moneyScoredFrom != nil || change.clearedReader != nil || change.activityLeavesICloud
    }
  }

  private func write(_ request: Request) async throws(ModuleChangeError) -> ModuleChange {
    let main = stores.main
    let source = issuer
    let now = now
    return try await call { () async throws(StoreError) in
      try await main.write { transaction in
        let plan = try Self.plan(request, in: ReadTransaction(database: transaction.database, registry: main.registry), issuer: source, now: now)
        if plan.needsWrite { try Self.write(plan, in: &transaction) }
        return plan.change
      }
    }
  }

  /// A vault without settings is refused a change and has nothing to enforce, since every module is on.
  private static func plan(_ request: Request, in transaction: ReadTransaction, issuer source: CommandIssuerSource, now: () -> Date) throws -> Plan {
    let settings = try settings(in: transaction)
    let before = ModuleSelection(settings: settings)
    let target: ModuleSelection
    switch request {
    case .change(let changes):
      guard settings != nil else { throw ModuleChangeError.settingsAbsent }
      target = try before.setting(changes)
    case .enforce:
      target = before
    }
    var fields = [MemoirModule: Bool]()
    if case .change = request, let settings {
      for module in MemoirModule.allCases where settings.isEnabled(module) != target.contains(module) { fields[module] = target.contains(module) }
    }
    let paused = target.contains(.quests) ? [] : try MemoirDerived.quests(in: transaction).filter(\.schedule.active).map(\.id)
    let scoresMoney = settings != nil && settings?.moneyScoredFrom == nil && !scoresMoney(before) && scoresMoney(target)
    let issuer = paused.isEmpty && !scoresMoney ? nil : try source.issuer(in: transaction)
    var scoredFrom: LocalDate?
    if scoresMoney, let issuer { scoredFrom = try accountDay(issuer, zone: try AccountZone.load(in: transaction), now: now()) }
    var reader: HealthReaderDesignation?
    var activityLeavesICloud = false
    if !target.contains(.body) {
      reader = try HealthSettings.designation(in: transaction)
      activityLeavesICloud = try HealthSettings.isActivityOnICloud(in: transaction)
    }
    let change = ModuleChange(
      before: before, after: target, pausedQuests: paused, moneyScoredFrom: scoredFrom, clearedReader: reader, activityLeavesICloud: activityLeavesICloud)
    return Plan(change: change, settings: settings, fields: fields, issuer: issuer)
  }

  private static func write(_ plan: Plan, in transaction: inout WriteTransaction) throws {
    let change = plan.change
    if let settings = plan.settings, !plan.fields.isEmpty || change.moneyScoredFrom != nil {
      var updated = settings
      for (module, enabled) in plan.fields { updated.setModule(module, enabled: enabled) }
      if let day = change.moneyScoredFrom { updated.moneyScoredFrom = day }
      let edited = updated
      try AccountSettingsRecord.edit(MemoirKey.accountSettings.ref, in: &transaction) { $0 = edited }
    }
    if let issuer = plan.issuer {
      for quest in change.pausedQuests {
        try issuer.issue(.questUpdate(QuestUpdate(questId: quest, patch: try QuestSchedulePatch(active: false))), in: &transaction)
      }
    }
    if change.clearedReader != nil { try HealthSettings.clearReader(in: &transaction) }
    if change.activityLeavesICloud { try HealthSettings.setActivityOnICloud(false, in: &transaction) }
  }

  private static func scoresMoney(_ selection: ModuleSelection) -> Bool {
    selection.contains(.hero) && selection.contains(.money)
  }

  /// The zone's date now, or the open day when a backward zone change left it ahead, as replay takes `max(issuedOn, open day)`.
  private static func accountDay(_ issuer: CommandIssuer, zone: AccountZone, now: Date) throws(CalendarError) -> LocalDate {
    guard let millis = Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) else { throw .dateOutOfRange }
    let date = try issuer.clock.localDate(at: millis)
    return max(date, zone.openDay ?? date)
  }

  private static func settings(in transaction: ReadTransaction) throws -> AccountSettingsRecord? {
    switch try AccountSettingsRecord.read(key: .accountSettings, in: transaction) {
    case .absent: return nil
    case .unreadable(let reason): throw MemoirRecordError.unreadable(MemoirKey.accountSettings.ref, reason)
    case .readable(let entry): return entry.record
    }
  }

  private func call<T>(_ body: () async throws(StoreError) -> T) async throws(ModuleChangeError) -> T {
    do {
      return try await body()
    } catch {
      throw ModuleChangeError(error)
    }
  }
}
