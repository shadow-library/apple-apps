import Foundation
import Observation
import ShadowSync
import ShadowSyncRuntime

/// Every action goes through the vault's one `SyncRuntime`, which runs calls one at a time, so two windows acting at once are told what the other did.
@MainActor
@Observable
final class SyncSettingsModel {
  enum Overview: Equatable {
    case loading
    /// Sync has no runtime: no vault is open, or this device has no place for sync's files.
    case unavailable
    /// Nil when sync was never set up on this device.
    case off(SyncTurnedOffReason?)
    case attached(SyncLocation, SyncPhase?)
    /// A move or follow started here has not finished; nil when its record cannot be read.
    case moving(SyncMoveJournal?)
    case unreadable(PresentedError)
  }

  enum Confirmation: Equatable {
    case disconnect
    case abandonMove
    case stayAfterMove
  }

  enum Work: Equatable {
    case disconnecting
    case continuingMove
    case abandoningMove
    case staying
  }

  enum Notice: Equatable {
    case disconnected
    case moveAbandoned
    case stayed
  }

  let sync: SyncRuntimes
  private(set) var overview = Overview.loading
  /// The keychain refuses this build (a Mac build signed without a team), as the runtime found; nothing can be connected, moved or followed.
  private(set) var isKeychainRefused = false
  private(set) var work: Work?
  private(set) var notice: Notice?
  var confirmation: Confirmation?
  var failure: PresentedError?
  private(set) var connect: SyncConnectModel?

  private var errors: SyncSettingsErrors { SyncSettingsErrors(app: sync.identity) }

  init(sync: SyncRuntimes) {
    self.sync = sync
  }

  var wiring: SyncWiring? { sync.wiring }

  var canChangeLocation: Bool { work == nil && !isKeychainRefused && connect?.isWorking != true }

  func refresh() async {
    guard let wiring, let runtime = sync.runtime else {
      overview = .unavailable
      return
    }
    let store: SyncLocationStore
    let record: SyncLocationRecord
    do throws(SyncLocationError) {
      store = try wiring.locationStore()
      record = try store.load()
    } catch {
      overview = .unreadable(errors.presented(error, kind: nil))
      return
    }
    let phase = await runtime.currentPhase
    isKeychainRefused = phase == .keychainUnavailable ? true : !(await runtime.keychainUsable())
    switch record {
    case .firstUse: overview = .off(nil)
    case .turnedOff(let reason): overview = .off(reason)
    case .attached(let location):
      do throws(SyncMoveError) {
        if let journal = try SyncMoveJournalStore(beside: store).load() {
          overview = .moving(journal)
          return
        }
      } catch {
        overview = .moving(nil)
        return
      }
      overview = .attached(location, phase)
    }
  }

  func startConnect() {
    begin(.connect)
  }

  func startMove() {
    begin(.move)
  }

  /// Follows the move named by the notice the attached vault holds: iCloud and S3 with saved keys go straight on, a folder asks to be chosen here.
  func startFollow(_ notice: VaultMoveNotice) async {
    guard let target = notice.targetLocation?.settings else {
      failure = PresentedError(
        headline: String(
          localized: "The move names a location this version of \(sync.identity.displayName) cannot read. Update \(sync.identity.displayName).", table: "SyncSettings",
          bundle: .module), detail: nil)
      return
    }
    guard let model = begin(.follow(target: target)) else { return }
    await model.begin()
  }

  /// The page went away (a sheet swiped down, the Settings window closed): an idle pass is cancelled at once, and one with work in flight finishes.
  func leave() {
    guard let connect, !connect.isWorking else { return }
    connect.cancel()
    self.connect = nil
  }

  func closeConnect() async {
    connect?.cancel()
    connect = nil
    await refresh()
  }

  func confirm(_ confirmation: Confirmation) {
    guard work == nil else { return }
    notice = nil
    failure = nil
    self.confirmation = confirmation
  }

  /// Waits for a sync in flight; the vault and the synced copy, with its keys, stay where they are.
  func disconnect() async {
    await perform(.disconnecting, notice: .disconnected) { runtime throws(SyncStartupError) in try await runtime.detach() }
  }

  func continueMove() async {
    guard case .moving(let journal?) = overview else { return }
    await perform(.continuingMove, notice: nil) { runtime throws(SyncMoveError) in
      switch journal {
      case .movingOut(_, let target): _ = try await runtime.moveVault(to: target.settings)
      case .following(_, let target): _ = try await runtime.followMove(to: target.settings)
      }
    }
  }

  func abandonMove() async {
    await perform(.abandoningMove, notice: .moveAbandoned) { runtime throws(SyncMoveError) in try await runtime.abandonMove() }
  }

  func stayAfterMove() async {
    await perform(.staying, notice: .stayed) { runtime throws(SyncMoveError) in try await runtime.stayAfterMove() }
  }

  @discardableResult
  private func begin(_ purpose: SyncConnectModel.Purpose) -> SyncConnectModel? {
    guard canChangeLocation, let wiring, let runtime = sync.runtime else { return nil }
    connect?.cancel()
    notice = nil
    failure = nil
    confirmation = nil
    let model = SyncConnectModel(purpose: purpose, runtime: runtime, wiring: wiring)
    connect = model
    return model
  }

  private func perform<E: Error>(_ work: Work, notice: Notice?, _ action: (SyncRuntime) async throws(E) -> Void) async {
    guard self.work == nil, let runtime = sync.runtime else { return }
    confirmation = nil
    failure = nil
    self.work = work
    defer { self.work = nil }
    do throws(E) {
      try await action(runtime)
      self.notice = notice
    } catch {
      if SyncSettingsErrors.isKeychainRefusal(error) { isKeychainRefused = true }
      failure = errors.presented(error, kind: kind)
    }
    await refresh()
  }

  private var kind: SyncProviderKind? {
    switch overview {
    case .attached(let location, _): location.kind
    case .moving(let journal?): journal.target.kind
    default: nil
    }
  }
}
