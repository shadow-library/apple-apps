import Foundation
import OSLog
import Observation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime

@MainActor
@Observable
final class VaultModel {
  enum State {
    case opening
    case ready(VaultStore)
    /// The device has not been unlocked since it started, so the vault's protected files cannot be read yet; it opens once protected data is available.
    case locked
    case failed(VaultOpenError)
  }

  typealias UnlockProbe = @Sendable () async -> Bool

  nonisolated private static let logger = Logger(subsystem: SyncWiring.app, category: "vault")

  private(set) var state = State.opening
  /// One for the life of the app: the store stamps changes with it, and sync records the storage's time into it.
  let trustedClock: TrustedClock
  private let locate: @Sendable () throws(VaultOpenError) -> StoreLocation
  private let hasUnlockedSinceBoot: UnlockProbe
  @ObservationIgnored private var opening: Task<Void, Never>?

  init(
    locate: @escaping @Sendable () throws(VaultOpenError) -> StoreLocation = { try VaultOpener.defaultLocation() }, trustedClock: TrustedClock = TrustedClock(),
    hasUnlockedSinceBoot: @escaping UnlockProbe = VaultModel.firstUnlockProbe
  ) {
    self.locate = locate
    self.trustedClock = trustedClock
    self.hasUnlockedSinceBoot = hasUnlockedSinceBoot
  }

  var store: VaultStore? {
    guard case .ready(let store) = state else { return nil }
    return store
  }

  var failure: VaultOpenError? {
    guard case .failed(let error) = state else { return nil }
    return error
  }

  var isLocked: Bool {
    guard case .locked = state else { return false }
    return true
  }

  /// A second call while the vault opens waits for the first, so a push that wakes the app can sync the vault the window is opening.
  func open() async {
    if let opening { return await opening.value }
    guard store == nil else { return }
    let task = Task {
      await attempt()
      opening = nil
    }
    opening = task
    await task.value
  }

  /// After the device's first unlock: a vault that waited for it opens, including one whose attempt was still deciding when the unlock arrived; any other
  /// state is left alone.
  func protectedDataBecameAvailable() async {
    if let opening { await opening.value }
    guard isLocked else { return }
    await open()
  }

  private func attempt() async {
    state = .opening
    do {
      state = .ready(try await Self.open(locate, wallClock: SyncEngine.wallClock(preferring: trustedClock)))
    } catch {
      guard await !hasUnlockedSinceBoot() else {
        state = .failed(error)
        return
      }
      Self.logger.notice("The vault waits for the device's first unlock code=\(error.code, privacy: .public)")
      state = .locked
    }
  }

  @concurrent
  private nonisolated static func open(
    _ locate: @Sendable () throws(VaultOpenError) -> StoreLocation, wallClock: @escaping @Sendable () -> Date
  ) async throws(VaultOpenError) -> VaultStore {
    try await VaultOpener.open(try locate(), wallClock: wallClock)
  }

  /// A Mac has no protection before the first unlock, so an open failure there is always a failure.
  nonisolated static func firstUnlockProbe() async -> Bool {
    #if os(macOS)
      return true
    #else
      guard let paths = try? SyncPaths.live() else { return true }
      return FirstUnlockProbe(url: paths.firstUnlock).hasUnlockedSinceBoot()
    #endif
  }
}
