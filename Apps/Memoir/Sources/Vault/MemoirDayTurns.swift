import Foundation
import MemoirCore
import OSLog
import ShadowAppShell
import ShadowCore

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Runs the open vault's `ProjectionDayTurns` for the life of the process, so the derived rows walk to each new day of the account's zone. A wait under
/// way does not notice the system clock or the device's zone changing, so either restarts the run, as does a return to the foreground.
final class MemoirDayTurns {
  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "day-turns") }

  nonisolated static var clockChanges: [Notification.Name] {
    #if os(macOS)
      [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange]
    #else
      [UIApplication.significantTimeChangeNotification, .NSSystemTimeZoneDidChange]
    #endif
  }

  private let center: NotificationCenter
  private let reportStopped: @Sendable (any Error) -> Void
  private var observers: [any NSObjectProtocol] = []
  private var vault: MemoirOpenedVault?
  private var running: Task<Void, Never>?

  init(
    center: NotificationCenter = .default, clockChanges: [Notification.Name] = clockChanges,
    reportStopped: @escaping @Sendable (any Error) -> Void = MemoirDayTurns.logStopped
  ) {
    self.center = center
    self.reportStopped = reportStopped
    observers = clockChanges.map { name in
      center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in Task { @MainActor in self?.restart() } }
    }
  }

  isolated deinit {
    running?.cancel()
    for observer in observers { center.removeObserver(observer) }
  }

  /// Starts following `opened`, keeps following a vault already followed, and stops when there is none.
  func follow(_ opened: MemoirOpenedVault?) {
    guard let opened else { return stop() }
    if let vault, vault.stores.main === opened.stores.main { return }
    vault = opened
    restart()
  }

  /// A restart cancels the run wherever it is, inside a refresh's write as well as in its wait, so a cancelled run is never reported.
  func restart() {
    guard let vault else { return }
    running?.cancel()
    let turns = vault.dayTurns
    let reportStopped = reportStopped
    running = Task {
      do {
        try await turns.run()
      } catch {
        guard !Task.isCancelled else { return }
        reportStopped(error)
      }
    }
  }

  nonisolated static func logStopped(_ error: any Error) {
    logger.error("The day turns stopped code=\((error as? any ShadowError)?.code ?? "unknown", privacy: .public)")
  }

  func stop() {
    running?.cancel()
    running = nil
    vault = nil
  }
}
