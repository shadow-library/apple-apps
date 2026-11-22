import Foundation
import ShadowSync
import ShadowSyncCloudKit
import ShadowSyncRuntime
import Synchronization

/// The app's one CloudKit client and provider for its container, made on first use and kept for the life of the process: CloudKit allows one sync engine per
/// database, and two providers of one container would share its index state. Exists only in builds signed with the iCloud and push capabilities.
nonisolated final class CloudKitAccess: Sendable {
  typealias ClientFactory = @Sendable (CloudKitConfiguration) throws(CloudKitConfigurationError) -> any CloudKitZoneClient

  private struct Made {
    let client: any CloudKitZoneClient
    let provider: CloudKitStorageProvider
  }

  let configuration: CloudKitConfiguration
  private let makeClient: ClientFactory
  private let stateStore: any CloudKitStateStore
  private let made = Mutex<Made?>(nil)

  init(configuration: CloudKitConfiguration, stateStore: any CloudKitStateStore, makeClient: @escaping ClientFactory) {
    self.configuration = configuration
    self.stateStore = stateStore
    self.makeClient = makeClient
  }

  static func live(configuration: CloudKitConfiguration, paths: SyncPaths) -> CloudKitAccess {
    CloudKitAccess(configuration: configuration, stateStore: CloudKitFileStateStore(fileURL: paths.cloudKitIndex)) { configuration throws(CloudKitConfigurationError) in
      try CKZoneClient(configuration: configuration, engineStateURL: paths.cloudKitEngineState)
    }
  }

  var settings: SyncICloudSettings { SyncICloudSettings(configuration) }

  /// A location saved by a build with another container or zone is refused rather than read from this one.
  func provider(for settings: SyncICloudSettings) throws(StorageError) -> CloudKitStorageProvider {
    guard settings == self.settings else { throw .unavailable("This build syncs with \(configuration.containerIdentifier), not \(settings.containerIdentifier).") }
    return try resolved().provider
  }

  /// The binding is a digest of the iCloud user record name, which tells one account from another.
  func account() async -> SyncAccountStatus {
    guard let client = try? resolved().client else { return .temporarilyUnavailable }
    do throws(CloudKitZoneError) {
      switch try await client.accountStatus() {
      case .available: return .available(SyncAccountBinding(kind: .iCloud, account: try await client.currentUserRecordName()))
      case .noAccount, .restricted: return .noAccount
      case .temporarilyUnavailable, .couldNotDetermine: return .temporarilyUnavailable
      }
    } catch {
      return .temporarilyUnavailable
    }
  }

  /// Asks CloudKit's sync engine to fetch, as on every foreground; does nothing before sync first needed the client.
  func refresh() async {
    guard let client = made.withLock({ $0?.client }) as? CKZoneClient else { return }
    await client.refresh()
  }

  private func resolved() throws(StorageError) -> Made {
    let result: Result<Made, StorageError> = made.withLock { made in
      if let made { return .success(made) }
      do throws(CloudKitConfigurationError) {
        let client = try makeClient(configuration)
        let fresh = Made(client: client, provider: CloudKitStorageProvider(client: client, stateStore: stateStore))
        made = fresh
        return .success(fresh)
      } catch {
        return .failure(.unavailable(error.localizedDescription))
      }
    }
    return try result.get()
  }
}
