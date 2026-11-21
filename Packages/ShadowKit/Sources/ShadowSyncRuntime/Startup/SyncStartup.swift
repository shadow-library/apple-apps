import Foundation
import OSLog
import ShadowCore
import ShadowKeychain
import ShadowSync

/// Works out where the vault stands on this device and, once it can, hands out what `SyncEngine` needs. Calls run one at a time.
/// A saved location is never replaced here: a different account or a different vault at the location stops sync until the user decides, and an
/// automatic provider attaches on its own only on first use, never after sync was turned off.
struct SyncMoveContext: Sendable {
  let source: SyncAttachment
  let target: SyncLocation
  let targetProvider: any StorageProvider
  let locations: SyncLocationStore
}

public actor SyncStartup {
  private static let logger = Logger(category: "SyncStartup")
  private static let keychainProbe = "keychain-probe"

  private struct CachedProvider {
    let id: Int
    let settings: SyncProviderSettings
    let provider: any StorageProvider
  }

  private let environment: SyncStartupEnvironment
  private var attachedProvider: CachedProvider?
  private var discoveryProvider: CachedProvider?
  private var providerCount = 0
  private var cachedRing: KeyRing?
  private var cachedKeyServices = SyncKeyServices()
  private var missingKeys: [KeyID: Set<ReplicaID>] = [:]
  private var isKeychainWritable = false
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(_ environment: SyncStartupEnvironment) {
    self.environment = environment
  }

  public func evaluate() async throws(SyncStartupError) -> SyncStartupResult {
    await acquire()
    defer { release() }
    guard await environment.hasUnlockedSinceBoot() else { return SyncStartupResult(phase: .deviceLocked) }
    let record: SyncLocationRecord
    do {
      record = try environment.locationStore.load()
    } catch {
      let failure = await locationFailure(error)
      guard failure != .deviceLocked else { return SyncStartupResult(phase: .deviceLocked) }
      throw failure
    }
    switch record {
    case .firstUse: return try await attachAutomatically()
    case .turnedOff(.disconnected): return SyncStartupResult(phase: .detached)
    case .turnedOff(.unreadable): return SyncStartupResult(phase: .settingsUnreadable)
    case .turnedOff(.newerFormat): return SyncStartupResult(phase: .appUpdateRequired)
    case .attached(let location):
      guard !isMoving() else { return SyncStartupResult(phase: .moveInProgress, location: location) }
      return try await evaluate(location, known: nil)
    }
  }

  /// The attached vault's attachment, whatever a move in progress says, and the location `settings` names for it with this device's account binding;
  /// nil names the attached location itself.
  func moveContext(to requested: SyncProviderSettings?) async throws(SyncStartupError) -> SyncMoveContext {
    await acquire()
    defer { release() }
    guard await environment.hasUnlockedSinceBoot() else { throw .deviceLocked }
    let record: SyncLocationRecord
    do {
      record = try environment.locationStore.load()
    } catch {
      throw await locationFailure(error)
    }
    guard case .attached(let location) = record else { throw .notAttached }
    let source = try await evaluate(location, known: nil)
    guard let attachment = source.attachment else { throw .unavailable(source.phase) }
    let settings = requested ?? location.settings
    let binding: SyncAccountBinding?
    switch await environment.account(settings) {
    case .available(nil) where settings.kind.distinguishesAccounts: throw .accountUnavailable
    case .available(let account): binding = account
    case .noAccount: throw .noStorageAccount
    case .temporarilyUnavailable: throw .accountUnavailable
    }
    let target = settings == location.settings ? location : SyncLocation(settings: settings, vault: location.vault, account: binding)
    return SyncMoveContext(source: attachment, target: target, targetProvider: try provider(for: settings).provider, locations: environment.locationStore)
  }

  /// An unreadable journal counts as a move in progress: running the old engine under a half-moved replica is what the journal prevents.
  private func isMoving() -> Bool {
    do {
      return try SyncMoveJournalStore(beside: environment.locationStore).load() != nil
    } catch {
      return true
    }
  }

  /// After a move saved the new location: the attached provider and the key services that hold it belong to the old one, and missing keys were named there.
  func rebound() {
    attachedProvider = nil
    cachedKeyServices = SyncKeyServices()
    missingKeys = [:]
  }

  public func discover(_ settings: SyncProviderSettings) async throws(SyncStartupError) -> VaultDiscovery {
    await acquire()
    defer { release() }
    let setup = try setup(for: settings)
    do {
      return try await setup.discover()
    } catch {
      throw .setup(error)
    }
  }

  /// The explicit "Create a vault here" or "Join the vault found here"; it also turns sync back on after `detach()`.
  public func attach(_ settings: SyncProviderSettings, choice: VaultChoice) async throws(SyncStartupError) -> SyncStartupResult {
    await acquire()
    defer { release() }
    guard await environment.hasUnlockedSinceBoot() else { throw .deviceLocked }
    let record: SyncLocationRecord
    do {
      record = try environment.locationStore.load()
    } catch {
      throw await locationFailure(error)
    }
    if case .attached = record { throw .alreadyAttached }
    let binding: SyncAccountBinding?
    switch await environment.account(settings) {
    case .available(nil) where settings.kind.distinguishesAccounts: throw .accountUnavailable
    case .available(let account): binding = account
    case .noAccount: throw .noStorageAccount
    case .temporarilyUnavailable: throw .accountUnavailable
    }
    try probeKeychain()
    let setup = try setup(for: settings)
    let vault: VaultID
    do {
      switch choice {
      case .create: vault = try await setup.create().vault
      case .join(let chosen): vault = try await setup.join(chosen)
      }
    } catch {
      throw Self.failure(of: error)
    }
    return try await bind(SyncLocation(settings: settings, vault: vault, account: binding))
  }

  /// False only when the keychain refuses this build (`errSecMissingEntitlement`), so nothing can be created or joined; a locked device answers true, since
  /// attaching reports that itself.
  public func keychainUsable() async -> Bool {
    await acquire()
    defer { release() }
    do throws(SyncStartupError) {
      try probeKeychain()
    } catch {
      return error != .keychainUnavailable
    }
    return true
  }

  /// Turns sync off: forgets the location and keeps the automatic provider from attaching again. The vault's files and keys stay where they are.
  public func detach() async throws(SyncStartupError) {
    await acquire()
    defer { release() }
    do {
      try environment.locationStore.turnOff()
    } catch {
      throw await locationFailure(error)
    }
    cachedRing = nil
    cachedKeyServices = SyncKeyServices()
    missingKeys = [:]
    attachedProvider = nil
  }

  /// The provider of the saved location, made once and kept while the location stays attached, whatever else `discover(_:)` looks at.
  func attachedStorage() -> (id: Int, provider: any StorageProvider)? {
    attachedProvider.map { ($0.id, $0.provider) }
  }

  /// Takes `SyncDownloadOutcome.missingKeys` from the latest download of `vault`, which read them from unauthenticated headers; ignored unless
  /// `vault` is the one attached here.
  public func noteMissingKeys(_ keys: [KeyID: Set<ReplicaID>], vault: VaultID) async {
    await acquire()
    defer { release() }
    guard cachedRing?.vault == vault else { return }
    missingKeys = keys
  }

  private func attachAutomatically() async throws(SyncStartupError) -> SyncStartupResult {
    guard let settings = environment.automatic else { return SyncStartupResult(phase: .detached) }
    let binding: SyncAccountBinding?
    switch await environment.account(settings) {
    case .available(nil) where settings.kind.distinguishesAccounts: return SyncStartupResult(phase: .accountUnavailable)
    case .available(let account): binding = account
    case .noAccount: return SyncStartupResult(phase: .vault(.noStorageAccount))
    case .temporarilyUnavailable: return SyncStartupResult(phase: .accountUnavailable)
    }
    if let refused = try keychainRefusal() { return SyncStartupResult(phase: refused) }
    let setup = try setup(for: settings)
    let vault: VaultID
    do {
      switch try await setup.discover() {
      case .found(let found): vault = found
      case .empty: vault = try await setup.create().vault
      case .newerFormat: return SyncStartupResult(phase: .appUpdateRequired)
      case .unrecognized: return SyncStartupResult(phase: .vaultUnrecognized)
      }
    } catch {
      guard let phase = Self.phase(for: error) else { throw .setup(error) }
      return SyncStartupResult(phase: phase)
    }
    return try await bind(SyncLocation(settings: settings, vault: vault, account: binding))
  }

  /// Saved only after the hint names the vault, so a crash before this point leaves a vault that the next evaluation finds and joins.
  private func bind(_ location: SyncLocation) async throws(SyncStartupError) -> SyncStartupResult {
    do {
      try environment.locationStore.save(location)
    } catch {
      throw await locationFailure(error)
    }
    Self.logger.info("Attached a sync location kind=\(location.kind.rawValue, privacy: .public) vault=\(location.vault.rawValue, privacy: .private)")
    return try await evaluate(location, known: .found(location.vault))
  }

  private func evaluate(_ location: SyncLocation, known: VaultDiscovery?) async throws(SyncStartupError) -> SyncStartupResult {
    switch await environment.account(location.settings) {
    case .noAccount, .temporarilyUnavailable:
      return SyncStartupResult(phase: .accountUnavailable, location: location)
    case .available(let binding):
      if location.account == nil, location.kind.distinguishesAccounts { return SyncStartupResult(phase: .accountUnavailable, location: location) }
      if let expected = location.account, binding != expected {
        return SyncStartupResult(phase: binding == nil ? .accountUnavailable : .accountChanged, location: location)
      }
    }
    if let refused = try keychainRefusal() { return SyncStartupResult(phase: refused, location: location) }
    let cached = try provider(for: location.settings)
    if attachedProvider?.id != cached.id {
      attachedProvider = cached
      if discoveryProvider?.id == cached.id { discoveryProvider = nil }
    }
    let setup = setup(with: cached.provider)
    let discovery: VaultDiscovery
    do {
      if let known { discovery = known } else { discovery = try await setup.discover() }
    } catch {
      guard let phase = Self.phase(for: error) else { throw .setup(error) }
      return SyncStartupResult(phase: phase, location: location)
    }
    switch discovery {
    case .empty: return SyncStartupResult(phase: .storageRemoved, location: location)
    case .newerFormat: return SyncStartupResult(phase: .appUpdateRequired, location: location)
    case .unrecognized: return SyncStartupResult(phase: .vaultUnrecognized, location: location)
    case .found(let found) where found != location.vault:
      return SyncStartupResult(phase: .vaultMismatch(expected: location.vault, found: found), location: location)
    case .found: break
    }
    if let blocked = try checkMarker(of: location.vault) { return SyncStartupResult(phase: blocked, location: location) }
    let ring = ring(for: location.vault)
    do {
      try ring.refresh()
    } catch {
      switch error {
      case .deviceLocked: return SyncStartupResult(phase: .deviceLocked, location: location)
      case .keychainUnavailable: return SyncStartupResult(phase: .keychainUnavailable, location: location)
      case .store, .conflictingKey: throw .keyRing(error)
      }
    }
    let observation = VaultObservation(storage: .available, vault: location.vault, heldKeys: Set(ring.keyIDs), namedKeys: missingKeys)
    let attachment = SyncAttachment(
      location: location, provider: setup.provider, providerID: cached.id, ring: ring, markerStore: environment.stores.marker, keyServices: cachedKeyServices)
    return SyncStartupResult(phase: .vault(VaultStartupState(observation)), location: location, attachment: attachment)
  }

  private func keychainRefusal() throws(SyncStartupError) -> SyncPhase? {
    do throws(SyncStartupError) {
      try probeKeychain()
    } catch .deviceLocked {
      return .deviceLocked
    } catch .keychainUnavailable {
      return .keychainUnavailable
    }
    return nil
  }

  /// A build without an application identifier reads every item as missing and is refused only when it adds or deletes one (`errSecMissingEntitlement`),
  /// so the probe writes, before any provider is made: S3 would read its credentials as missing. Only a success is kept, since entitlements never change.
  private func probeKeychain() throws(SyncStartupError) {
    guard !isKeychainWritable else { return }
    let store = environment.stores.marker
    do {
      _ = try store.insertData(Data(), forKey: Self.keychainProbe)
      try store.removeValue(forKey: Self.keychainProbe)
    } catch {
      if error.isInteractionNotAllowed { throw .deviceLocked }
      if error.isMissingEntitlement { throw .keychainUnavailable }
      throw .marker(error.reason)
    }
    isKeychainWritable = true
  }

  /// The phase that keeps the vault from starting while the keychain is locked or refuses this build, nil otherwise. A marker that is not a replica id is
  /// cleared once the device is unlocked, so the next start re-mints the replica: claiming the store's id instead could give a copied database the original's id.
  private func checkMarker(of vault: VaultID) throws(SyncStartupError) -> SyncPhase? {
    let marker = DeviceMarker(store: environment.stores.marker)
    let name = DeviceMarker.itemName(vault: vault)
    let data: Data?
    do {
      data = try environment.stores.marker.data(forKey: name)
    } catch {
      if error.isInteractionNotAllowed { return .deviceLocked }
      if error.isMissingEntitlement { return .keychainUnavailable }
      throw .marker(error.reason)
    }
    guard let data, String(data: data, encoding: .utf8).flatMap(ReplicaID.init) == nil else { return nil }
    do {
      try marker.clear(vault: vault)
    } catch {
      throw .marker(error.code)
    }
    Self.logger.warning("Cleared an unreadable device marker; the replica will be re-minted")
    return nil
  }

  /// A refused file means data protection only while the device has not been unlocked since it started; afterwards it is a real failure.
  private func locationFailure(_ error: SyncLocationError) async -> SyncStartupError {
    guard case .permissionDenied = error else { return .location(error) }
    return await environment.hasUnlockedSinceBoot() ? .location(error) : .deviceLocked
  }

  private func setup(for settings: SyncProviderSettings) throws(SyncStartupError) -> VaultSetup {
    setup(with: try provider(for: settings).provider)
  }

  private func setup(with provider: any StorageProvider) -> VaultSetup {
    VaultSetup(provider: provider, ringStore: environment.stores.ring, makeVaultID: environment.makeVaultID, makeKeyID: environment.makeKeyID)
  }

  /// One provider for the attached location and one for the latest discovery elsewhere, so looking at another location never makes a second
  /// provider for the attached one; two CloudKit providers of one container would share its index state.
  private func provider(for settings: SyncProviderSettings) throws(SyncStartupError) -> CachedProvider {
    if let attachedProvider, attachedProvider.settings == settings { return attachedProvider }
    if let discoveryProvider, discoveryProvider.settings == settings { return discoveryProvider }
    do {
      providerCount += 1
      let made = CachedProvider(id: providerCount, settings: settings, provider: try environment.provider(settings))
      discoveryProvider = made
      return made
    } catch {
      throw .storage(error)
    }
  }

  private func ring(for vault: VaultID) -> KeyRing {
    if let cachedRing, cachedRing.vault == vault { return cachedRing }
    let ring = KeyRing(vault: vault, store: environment.stores.ring, makeKeyID: environment.makeKeyID)
    cachedRing = ring
    cachedKeyServices = SyncKeyServices()
    missingKeys = [:]
    return ring
  }

  private static func failure(of error: VaultSetupError) -> SyncStartupError {
    switch error {
    case .deviceLocked: .deviceLocked
    case .keyRing(.keychainUnavailable): .keychainUnavailable
    default: .setup(error)
    }
  }

  private static func phase(for error: VaultSetupError) -> SyncPhase? {
    switch error {
    case .deviceLocked: .deviceLocked
    case .keyRing(.keychainUnavailable): .keychainUnavailable
    case .storage(.unauthenticated): .accountUnavailable
    case .newerFormat: .appUpdateRequired
    case .unrecognized: .vaultUnrecognized
    default: nil
    }
  }

  private func acquire() async {
    while isBusy { await withCheckedContinuation { waiters.append($0) } }
    isBusy = true
  }

  private func release() {
    isBusy = false
    guard !waiters.isEmpty else { return }
    waiters.removeFirst().resume()
  }
}
