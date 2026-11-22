import Foundation
import OSLog
import Observation
import ShadowCore
import ShadowSync

/// The app's vault for the life of the process: `Opened` is what the app opens from it (one `VaultStore`, or several stores together), made by the app's
/// opener off the main actor.
@MainActor
@Observable
public final class VaultModel<Opened: Sendable> {
  public enum State {
    case opening
    case ready(Opened)
    /// The device has not been unlocked since it started, so the vault's protected files cannot be read yet; it opens once protected data is available.
    case locked
    case failed(VaultOpenError)
  }

  /// Opens the vault, stamping its changes with `wallClock`; it runs off the main actor.
  public typealias Opener = @concurrent @Sendable (_ wallClock: @escaping @Sendable () -> Date) async throws(VaultOpenError) -> Opened
  public typealias UnlockProbe = @Sendable () async -> Bool

  public private(set) var state = State.opening
  /// One for the life of the app: the store stamps changes with it, and sync records the storage's time into it.
  public let trustedClock: TrustedClock
  private let opener: Opener
  private let hasUnlockedSinceBoot: UnlockProbe
  @ObservationIgnored private var opening: Task<Void, Never>?

  public init(open: @escaping Opener, trustedClock: TrustedClock = TrustedClock(), hasUnlockedSinceBoot: @escaping UnlockProbe = VaultDirectory.hasUnlockedSinceBoot) {
    self.opener = open
    self.trustedClock = trustedClock
    self.hasUnlockedSinceBoot = hasUnlockedSinceBoot
  }

  public var opened: Opened? {
    guard case .ready(let opened) = state else { return nil }
    return opened
  }

  public var failure: VaultOpenError? {
    guard case .failed(let error) = state else { return nil }
    return error
  }

  public var isLocked: Bool {
    guard case .locked = state else { return false }
    return true
  }

  /// A second call while the vault opens waits for the first, so a push that wakes the app can sync the vault the window is opening.
  public func open() async {
    if let opening { return await opening.value }
    guard opened == nil else { return }
    let task = Task {
      await attempt()
      opening = nil
    }
    opening = task
    await task.value
  }

  /// After the device's first unlock: a vault that waited for it opens, including one whose attempt was still deciding when the unlock arrived; any other
  /// state is left alone.
  public func protectedDataBecameAvailable() async {
    if let opening { await opening.value }
    guard isLocked else { return }
    await open()
  }

  private func attempt() async {
    state = .opening
    do {
      state = .ready(try await opener(SyncEngine.wallClock(preferring: trustedClock)))
    } catch {
      guard await !hasUnlockedSinceBoot() else {
        state = .failed(error)
        return
      }
      vaultLogger.notice("The vault waits for the device's first unlock code=\(error.code, privacy: .public)")
      state = .locked
    }
  }
}

private nonisolated let vaultLogger = Logger(category: "vault")
