import Foundation
import Observation
import ShadowCore
import ShadowSync
import ShadowSyncRuntime

/// The Keys and Devices page: whether this device holds the library's key, the recovery phrase, the devices that have shown they hold each key, and
/// the flows that bring a key here or send it to another device. Everything goes through the runtime's key services, fetched again when they go stale.
@MainActor
@Observable
final class SyncKeysModel {
  nonisolated static let keyCheckInterval = Duration.seconds(30)

  struct Keys: Equatable {
    let vault: VaultID
    let holdsKey: Bool
    /// Nil until read, or while this device holds no key.
    var recovery: RecoveryStanding?
    var recoveryFailure: PresentedError?
    var holdings: [SyncKeyHolding]?
    var holdingsFailure: PresentedError?
  }

  enum Overview: Equatable {
    case loading
    case unavailable(String)
    case ready(Keys)
  }

  enum Flow {
    case setup(RecoveryPhraseSetupModel)
    case recover(PhraseRecoveryModel)
    case request(KeyRequestModel)
    case respond(KeyResponseModel)
  }

  enum Notice: Equatable {
    case keyArrived
    case phraseSaved
    case flowStopped(String)
  }

  let sync: SyncRuntimes
  private(set) var overview = Overview.loading
  private(set) var flow: Flow?
  private(set) var notice: Notice?
  private(set) var failure: PresentedError?
  @ObservationIgnored private let record: RecoveryPhraseRecord
  @ObservationIgnored private var source: SyncKeyServicesSource?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var pendingStart: SyncKeysStart

  /// `start` is honoured once, by the first refresh that finds this device holding the key with no phrase set up.
  init(sync: SyncRuntimes, record: RecoveryPhraseRecord = RecoveryPhraseRecord(), start: SyncKeysStart = .overview) {
    self.sync = sync
    self.record = record
    pendingStart = start
  }

  var keys: Keys? {
    guard case .ready(let keys) = overview else { return nil }
    return keys
  }

  /// This device has no key at all, so it waits for one from the user's other devices.
  var isWaitingForKey: Bool { keys?.holdsKey == false }

  /// Files from some devices are sealed with a key that has not reached this device, though it holds another.
  var lacksSomeKeys: Bool {
    switch sync.status {
    case .attentionNeeded(.writingKeyMissing), .attentionNeeded(.keysMissing): keys?.holdsKey == true
    default: false
    }
  }

  /// `holders` reads which devices hold each key, a listing and a file per device at the location; a status change alone keeps the last answer. The page
  /// shows before that survey answers, and a refresh that a newer one overtook changes nothing.
  func refresh(holders: Bool = true) async {
    generation += 1
    let current = generation
    guard let runtime = sync.runtime else {
      stopFlow(because: nil)
      overview = .unavailable(SyncKeysErrors.unavailable(.detached))
      return
    }
    if source?.runtime !== runtime { source = SyncKeyServicesSource(runtime: runtime) }
    guard let source else { return }
    let access: SyncKeyAccess
    do throws(SyncKeysError) {
      access = try await source.reload()
    } catch {
      guard current == generation else { return }
      stopFlow(because: SyncKeysErrors.headline(for: error))
      overview = .unavailable(SyncKeysErrors.headline(for: error))
      return
    }
    var keys = Keys(vault: access.vault, holdsKey: access.holdsKey)
    if keys.holdsKey {
      do throws(RecoveryError) {
        keys.recovery = try await access.recoveryStatus().standing(ofRecipient: record.recipientID(for: access.vault))
      } catch {
        keys.recoveryFailure = SyncKeysErrors.presented(.recovery(error))
      }
    }
    guard current == generation else { return }
    if let flowVault, flowVault != access.vault { stopFlow(because: SyncKeysErrors.headline(for: .vaultChanged)) }
    let previous = self.keys
    if previous?.holdsKey == false, keys.holdsKey { notice = .keyArrived }
    let reuses = !holders && previous?.vault == keys.vault && previous?.holdsKey == true && previous?.holdings != nil
    if reuses { keys.holdings = previous?.holdings }
    overview = .ready(keys)
    if pendingStart == .phraseSetup, keys.recovery != nil {
      pendingStart = .overview
      if keys.recovery == .notSetUp, flow == nil { await startSetup() }
    }
    guard current == generation, keys.holdsKey, !reuses else { return }
    let surveyed: Result<[SyncKeyHolding], RecoveryError>
    do throws(RecoveryError) {
      surveyed = .success(try await access.keyHolders())
    } catch {
      surveyed = .failure(error)
    }
    guard current == generation, var latest = self.keys, latest.vault == keys.vault else { return }
    switch surveyed {
    case .success(let holdings): latest.holdings = holdings
    case .failure(let error): latest.holdingsFailure = SyncKeysErrors.presented(.recovery(error))
    }
    overview = .ready(latest)
  }

  /// Asks the runtime to look for the key now, as foregrounding does; the keychain may have delivered it since the last look.
  func checkForKey() async {
    guard isWaitingForKey || lacksSomeKeys, let runtime = sync.runtime else { return }
    await runtime.foreground()
    await refresh(holders: false)
  }

  /// Looks for the key every `interval` for as long as the calling task runs and this device waits for it.
  func watchForKey(every interval: Duration = keyCheckInterval) async {
    while isWaitingForKey {
      do {
        try await Task.sleep(for: interval)
      } catch {
        return
      }
      await checkForKey()
    }
  }

  func startSetup() async {
    guard let keys, keys.holdsKey, let source else { return }
    await start { () async throws(SyncKeysError) -> Flow in
      let access = try await source.current()
      return .setup(RecoveryPhraseSetupModel(vault: keys.vault, pending: access.beginRecoveryPhrase(), source: source, record: record))
    }
  }

  func startRecovery() async {
    guard let keys, let source else { return }
    await start { () async throws(SyncKeysError) -> Flow in .recover(PhraseRecoveryModel(vault: keys.vault, source: source, record: record)) }
  }

  func startRequest() async {
    guard let keys, let source else { return }
    await start { () async throws(SyncKeysError) -> Flow in
      let access = try await source.current()
      return .request(KeyRequestModel(vault: keys.vault, request: access.requestKeys()))
    }
  }

  func startResponse() async {
    guard let keys, keys.holdsKey, let source else { return }
    await start { () async throws(SyncKeysError) -> Flow in .respond(KeyResponseModel(vault: keys.vault, source: source)) }
  }

  /// Closes the flow on screen, finished or not, and reads the page again.
  func closeFlow() async {
    if case .setup(let setup) = flow, case .finished = setup.step { notice = .phraseSaved }
    cancelFlow()
    await refresh()
  }

  /// The page went away: whatever a flow held (the phrase, typed words, an exchange) goes with it.
  func leave() {
    cancelFlow()
  }

  private func start(_ make: () async throws(SyncKeysError) -> Flow) async {
    cancelFlow()
    notice = nil
    failure = nil
    do throws(SyncKeysError) {
      flow = try await make()
    } catch {
      failure = SyncKeysErrors.presented(error)
    }
  }

  private var flowVault: VaultID? {
    switch flow {
    case .setup(let model)?: model.vault
    case .recover(let model)?: model.vault
    case .request(let model)?: model.vault
    case .respond(let model)?: model.vault
    case nil: nil
    }
  }

  private func stopFlow(because reason: String?) {
    guard flow != nil else { return }
    cancelFlow()
    if let reason { notice = .flowStopped(reason) }
  }

  private func cancelFlow() {
    switch flow {
    case .setup(let model)?: model.cancel()
    case .recover(let model)?: model.cancel()
    case .request(let model)?: model.cancel()
    case .respond(let model)?: model.cancel()
    case nil: break
    }
    flow = nil
  }
}
