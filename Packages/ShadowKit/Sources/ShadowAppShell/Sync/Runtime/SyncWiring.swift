import Foundation
import OSLog
import ShadowCore
import ShadowNetworking
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowSyncS3

#if canImport(UIKit)
  import UIKit
#elseif canImport(SystemConfiguration)
  import SystemConfiguration
#endif

/// What `SyncRuntime` needs on this device: the location file, keychain stores, providers and account checks. iCloud is attached on its own on first
/// use and offered at all only when the build was signed with it; a local folder and S3 work in every build, and OneDrive and Google Drive wait for their
/// sign-in.
nonisolated struct SyncWiring: Sendable {
  private static let logger = Logger(category: "sync")

  let identity: AppIdentity
  let paths: SyncPaths
  let stores: SyncSecureStores
  let cloudKit: CloudKitAccess?
  let device: ReplicaDevice
  let folders: LocalFolderAccess
  let s3Transport: any HTTPTransport

  init(
    identity: AppIdentity, paths: SyncPaths, stores: SyncSecureStores, cloudKit: CloudKitAccess?, device: ReplicaDevice, folders: LocalFolderAccess = LocalFolderAccess(),
    s3Transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.identity = identity
    self.paths = paths
    self.stores = stores
    self.cloudKit = cloudKit
    self.device = device
    self.folders = folders
    self.s3Transport = s3Transport
  }

  @MainActor
  static func live(
    identity: AppIdentity, capabilities: SyncCapabilities = .current, bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) throws(VaultOpenError) -> SyncWiring {
    let paths = try SyncPaths.live(bundleIdentifier: bundleIdentifier)
    return SyncWiring(
      identity: identity, paths: paths, stores: .keychain(app: identity.id, sharedAccessGroup: capabilities.sharedKeychainGroup),
      cloudKit: capabilities.cloudKit.map { CloudKitAccess.live(configuration: $0, paths: paths) }, device: thisDevice())
  }

  func locationStore() throws(SyncLocationError) -> SyncLocationStore {
    try SyncLocationStore(url: paths.location, outside: [paths.vaultDirectory])
  }

  func environment() throws(SyncLocationError) -> SyncStartupEnvironment {
    let firstUnlock = FirstUnlockProbe(url: paths.firstUnlock)
    return SyncStartupEnvironment(
      locationStore: try locationStore(), stores: stores, automatic: cloudKit.map { .iCloud($0.settings) },
      provider: { settings throws(StorageError) in try provider(for: settings) }, account: { settings in await account(for: settings) },
      hasUnlockedSinceBoot: { firstUnlock.hasUnlockedSinceBoot() })
  }

  /// `store` must have been opened with `SyncEngine.wallClock(preferring: trustedClock)`.
  func runtime(store: VaultStore, trustedClock: TrustedClock) throws(SyncLocationError) -> SyncRuntime {
    let cloudKit = cloudKit
    return SyncRuntime(
      environment: try environment(), store: store, device: device, trustedClock: trustedClock, wallClock: SyncEngine.wallClock(preferring: trustedClock),
      refresh: { await cloudKit?.refresh() })
  }

  func provider(for settings: SyncProviderSettings) throws(StorageError) -> any StorageProvider {
    switch settings {
    case .iCloud(let iCloud):
      guard let cloudKit else { throw .unavailable("This build of \(identity.displayName) cannot sync with iCloud.") }
      return try cloudKit.provider(for: iCloud)
    case .localFolder(let folder):
      let resolved = try folders.resolve(folder)
      if let refreshed = resolved.refreshed { saveRefreshedBookmark(refreshed, replacing: folder) }
      return try LocalFolderProvider(root: resolved.url)
    case .s3(let s3):
      return try s3Provider(s3)
    case .oneDrive, .googleDrive:
      throw .unavailable("This version of \(identity.displayName) cannot sign in to \(settings.kind.rawValue) yet.")
    }
  }

  func account(for settings: SyncProviderSettings) async -> SyncAccountStatus {
    switch settings {
    case .iCloud: await cloudKit?.account() ?? .noAccount
    case .localFolder, .s3: .available(nil)
    case .oneDrive, .googleDrive: .temporarilyUnavailable
    }
  }

  private func s3Provider(_ settings: SyncS3Settings) throws(StorageError) -> S3StorageProvider {
    let configuration: S3Configuration
    do {
      configuration = try settings.configuration()
    } catch {
      throw .unavailable(error.localizedDescription)
    }
    let credentials: S3Credentials?
    do {
      credentials = try stores.s3Credentials.load(for: settings)
    } catch {
      Self.logger.warning("S3 credentials unreadable code=\(error.code, privacy: .public)")
      throw .unavailable(error.localizedDescription)
    }
    guard let credentials else { throw .unauthenticated }
    return s3Provider(configuration, credentials: credentials)
  }

  func s3Provider(_ configuration: S3Configuration, credentials: S3Credentials) -> S3StorageProvider {
    S3StorageProvider(configuration: configuration, credentials: credentials, transport: s3Transport)
  }

  /// Only over the attached location that still names `folder`, and never while a move is recorded: a move compares the saved location with its target.
  private func saveRefreshedBookmark(_ refreshed: SyncLocalFolderSettings, replacing folder: SyncLocalFolderSettings) {
    do {
      let store = try locationStore()
      guard case .attached(let location) = try store.load(), location.settings == .localFolder(folder) else { return }
      guard try SyncMoveJournalStore(beside: store).load() == nil else { return }
      try store.save(SyncLocation(settings: .localFolder(refreshed), vault: location.vault, account: location.account))
      Self.logger.info("Renewed the sync folder's stale bookmark")
    } catch {
      Self.logger.warning("The sync folder's renewed bookmark was not saved code=\((error as? any ShadowError)?.code ?? "unknown", privacy: .public)")
    }
  }

  @MainActor
  private static func thisDevice() -> ReplicaDevice {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    #if canImport(UIKit)
      return ReplicaDevice(name: UIDevice.current.model, platform: UIDevice.current.systemName, appVersion: version)
    #else
      let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
      return ReplicaDevice(name: name, platform: "macOS", appVersion: version)
    #endif
  }
}
