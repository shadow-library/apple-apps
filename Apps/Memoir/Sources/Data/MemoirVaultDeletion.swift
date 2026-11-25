import Foundation
import MemoirCore
import OSLog
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore
import ShadowSyncRuntime

nonisolated enum VaultDeletionError: ShadowError, Equatable {
  case notOpen
  case locationUnavailable(String)
  case syncNotStopped(SyncStartupError)
  case eraseFailed(String)

  var code: String {
    switch self {
    case .notOpen: "memoir_deletion.not_open"
    case .locationUnavailable: "memoir_deletion.location_unavailable"
    case .syncNotStopped(let error): error.code
    case .eraseFailed: "memoir_deletion.erase_failed"
    }
  }

  var errorDescription: String? {
    switch self {
    case .notOpen: "the vault is not open"
    case .locationUnavailable(let reason), .eraseFailed(let reason): reason
    case .syncNotStopped(let error): error.errorDescription
    }
  }
}

/// Deletes the vault on this device and starts it again empty, so the app returns to onboarding. Sync is turned off first (`SyncRuntime.detach()`,
/// which keeps a later launch from attaching the old location on its own) and every runtime stops; a failure there erases nothing. Then the day turns,
/// reminders (pending and delivered), insights, exchange rates, the modules' effects and the budget closes (an enforce or a close under way included)
/// stop, the vault closes while its three store directories (blobs included), the waiting export archives and this device's Memoir defaults are
/// removed, and it opens again. What sync already sent stays at its location and on the other devices, since nothing in the sync kernel deletes a vault
/// there, and the keychain keeps the vault's synced keys, which those devices still use.
@MainActor
@Observable
final class MemoirVaultDeletion {
  enum Notice: Equatable {
    case erased
    case incomplete(code: String)
  }

  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "deletion") }

  /// What happened once the vault had closed, shown over whatever screen the reopened vault brings up.
  var notice: Notice?

  @ObservationIgnored private let vault: MemoirVaultModel
  @ObservationIgnored private let sync: SyncRuntimes
  @ObservationIgnored private let dayTurns: MemoirDayTurns
  @ObservationIgnored private let reminders: ReminderScheduler
  @ObservationIgnored private let insights: MemoirInsights
  @ObservationIgnored private let rates: MemoirRates?
  @ObservationIgnored private let modules: MemoirModuleEffects?
  @ObservationIgnored private let closer: BudgetPeriodCloser?
  @ObservationIgnored private let location: @Sendable () throws(MemoirVaultOpenError) -> MemoirVaultLocation
  @ObservationIgnored private let defaults: MemoirDeviceDefaults
  @ObservationIgnored private let exports: MemoirExports
  @ObservationIgnored private let vaultChanged: @MainActor () async -> Void
  @ObservationIgnored private var running: Task<Result<Void, VaultDeletionError>, Never>?

  init(
    vault: MemoirVaultModel, sync: SyncRuntimes, dayTurns: MemoirDayTurns, reminders: ReminderScheduler, insights: MemoirInsights,
    rates: MemoirRates? = nil, modules: MemoirModuleEffects? = nil, closer: BudgetPeriodCloser? = nil,
    location: @escaping @Sendable () throws(MemoirVaultOpenError) -> MemoirVaultLocation = MemoirVaultOpener.appLocation,
    defaults: UserDefaults = .standard, exports: MemoirExports = .live, vaultChanged: @escaping @MainActor () async -> Void
  ) {
    self.vault = vault
    self.sync = sync
    self.dayTurns = dayTurns
    self.reminders = reminders
    self.insights = insights
    self.rates = rates
    self.modules = modules
    self.closer = closer
    self.location = location
    self.defaults = MemoirDeviceDefaults(defaults: defaults)
    self.exports = exports
    self.vaultChanged = vaultChanged
  }

  /// Throws only when nothing was erased; once the vault has closed the outcome is `notice`. A second call while one runs waits for it.
  func delete() async throws(VaultDeletionError) {
    if let running { return try await running.value.get() }
    let task = Task { await run() }
    running = task
    defer { running = nil }
    try await task.value.get()
  }

  private func run() async -> Result<Void, VaultDeletionError> {
    guard let stores = vault.opened?.stores else { return .failure(.notOpen) }
    let location: MemoirVaultLocation
    do {
      location = try self.location()
    } catch {
      return .failure(.locationUnavailable(error.code))
    }
    if let runtime = sync.runtime {
      do {
        try await runtime.detach()
      } catch {
        return .failure(.syncNotStopped(error))
      }
    }
    await sync.shutDown()
    dayTurns.stop()
    reminders.withdrawAll()
    await insights.follow(nil)
    rates?.follow(nil)
    await modules?.stop()
    await closer?.stop()
    await Self.clearLocalTables(in: stores)
    do {
      let exports = exports
      let defaults = defaults
      try await vault.reopen { () throws(VaultDeletionError) in
        defer { defaults.forget() }
        try await Self.erase(stores, at: location, exports: exports)
      }
      notice = .erased
    } catch {
      Self.logger.error("The vault was not fully erased code=\(error.code, privacy: .public)")
      notice = .incomplete(code: error.code)
    }
    reminders.deviceSettingCleared()
    rates?.deviceSettingCleared()
    await vaultChanged()
    return .success(())
  }

  /// The files take these tables with them, but a directory that cannot be removed would keep this device's own answers and Health anchors.
  private static func clearLocalTables(in stores: MemoirStores) async {
    do {
      try await stores.main.write { transaction in try WeeklyReviewAnswers.clear(in: transaction.database) }
      try await HealthImport.forgetLocalState(in: stores)
    } catch {
      logger.notice("A local table was not cleared before the files went code=\((error as? any ShadowError)?.code ?? "unknown", privacy: .public)")
    }
  }

  /// Closes the stores so nothing writes to a file while it goes, then removes every store directory it can and the waiting archives; reports the first
  /// that stayed. A store something still holds open is removed all the same.
  @concurrent
  private static func erase(_ stores: MemoirStores, at location: MemoirVaultLocation, exports: MemoirExports) async throws(VaultDeletionError) {
    let fileManager = FileManager.default
    var failure: VaultDeletionError?
    for kind in MemoirStoreKind.allCases {
      do {
        try stores.store(kind).close()
      } catch {
        logger.notice("A store was still in use as its files went code=\(error.code, privacy: .public)")
      }
    }
    if case .vault(let vault) = location {
      for kind in MemoirStoreKind.allCases {
        let directory = vault.databaseURL(kind).deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { continue }
        do {
          try fileManager.removeItem(at: directory)
        } catch {
          failure = failure ?? .eraseFailed(error.localizedDescription)
        }
      }
    }
    do {
      try exports.clear(fileManager: fileManager)
    } catch {
      failure = failure ?? .eraseFailed(error.localizedDescription)
    }
    if let failure { throw failure }
  }
}
