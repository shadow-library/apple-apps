import ShadowStore
import ShadowSyncRuntime
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Owns the vault and its sync for the life of the process, not of a window: a silent push may wake the app with no window to open them, and on the Mac
/// quitting must reach them after every window has closed.
final class NovelForgeAppDelegate: NSObject {
  static let pushDeadline = Duration.seconds(25)

  let vault = VaultModel(locate: { () throws(VaultOpenError) -> StoreLocation in try VaultOpener.appLocation() })
  let sync = SyncRuntimes.live()
  private var observers: [any NSObjectProtocol] = []

  /// Opens the vault if no window has yet, then starts its sync; both wait for a call already in flight.
  func openAndSync() async {
    await vault.open()
    guard let store = vault.store else { return }
    await sync.launch(store, trustedClock: vault.trustedClock)
  }

  private func syncAfterPush() async -> Bool {
    var noticed = false
    _ = await SyncBackgroundWork.bounded(Self.pushDeadline) {
      await self.openAndSync()
      noticed = await self.sync.changeNotice()
    }
    return noticed
  }

  private func observe(_ name: Notification.Name, _ handle: @escaping @MainActor () async -> Void) {
    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in await handle() } })
  }
}

#if os(macOS)
  extension NovelForgeAppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      observe(NSWindow.willCloseNotification) { await UnsavedWork.shared.flushAll(within: .seconds(3)) }
      observe(NSApplication.didBecomeActiveNotification) { [sync] in await sync.activated() }
      observe(NSWindow.didBecomeMainNotification) { [sync] in await sync.activated() }
      if SyncCapabilities.current.receivesPushes { NSApplication.shared.registerForRemoteNotifications() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
      Task { _ = await syncAfterPush() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      guard UnsavedWork.shared.hasWork || sync.status != .off else { return .terminateNow }
      Task { @MainActor in
        await UnsavedWork.shared.flushAll(within: .seconds(3))
        await sync.uploadBeforeQuitting(within: .seconds(3))
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
  }
#else
  extension NovelForgeAppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
      observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
        guard let self else { return }
        await vault.protectedDataBecameAvailable()
        guard let store = vault.store else { return }
        await sync.launch(store, trustedClock: vault.trustedClock)
      }
      if SyncCapabilities.current.receivesPushes { application.registerForRemoteNotifications() }
      return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
      await syncAfterPush() ? .newData : .noData
    }
  }
#endif

struct UnsavedWorkFlush: ViewModifier {
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content.onChange(of: scenePhase) {
      guard scenePhase != .active else { return }
      Task { await UnsavedWork.shared.flushBeforeSuspending() }
    }
  }
}

extension View {
  func flushingUnsavedWork() -> some View {
    modifier(UnsavedWorkFlush())
  }
}
