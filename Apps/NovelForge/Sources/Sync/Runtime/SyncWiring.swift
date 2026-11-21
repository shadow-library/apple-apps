import Foundation
import OSLog
import ShadowCore
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
  static let app = "com.shadow.apps.novelforge"
  private static let logger = Logger(subsystem: app, category: "sync")

  let paths: SyncPaths
  let stores: SyncSecureStores
  let cloudKit: CloudKitAccess?
  let device: ReplicaDevice
  let folders: LocalFolderAccess

  init(paths: SyncPaths, stores: SyncSecureStores, cloudKit: CloudKitAccess?, device: ReplicaDevice, folders: LocalFolderAccess = LocalFolderAccess()) {
    self.paths = paths
    self.stores = stores
    self.cloudKit = cloudKit
    self.device = device
    self.folders = folders
  }

  @MainActor
  static func live(capabilities: SyncCapabilities = .current) throws(VaultOpenError) -> SyncWiring {
    let paths = try SyncPaths.live()
    return SyncWiring(
      paths: paths, stores: .keychain(app: app, sharedAccessGroup: capabilities.sharedKeychainGroup),
      cloudKit: capabilities.cloudKit.map { CloudKitAccess.live(configuration: $0, paths: paths) }, device: thisDevice())
  }

  func environment() throws(SyncLocationError) -> SyncStartupEnvironment {
    let firstUnlock = FirstUnlockProbe(url: paths.firstUnlock)
    return SyncStartupEnvironment(
      locationStore: try SyncLocationStore(url: paths.location, outside: [paths.vaultDirectory]), stores: stores, automatic: cloudKit.map { .iCloud($0.settings) },
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
      guard let cloudKit else { throw .unavailable("This build of Novel Forge cannot sync with iCloud.") }
      return try cloudKit.provider(for: iCloud)
    case .localFolder(let folder):
      return try LocalFolderProvider(root: try folders.root(for: folder))
    case .s3(let s3):
      return try s3Provider(s3)
    case .oneDrive, .googleDrive:
      throw .unavailable("This version of Novel Forge cannot sign in to \(settings.kind.rawValue) yet.")
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
    return S3StorageProvider(configuration: configuration, credentials: credentials)
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
