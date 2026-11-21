import ShadowStore
import ShadowSyncRuntime
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Owns the vault, its sync and its jobs for the life of the process, not of a window: a silent push may wake the app with no window to open them, a Mac
/// in worker mode runs them with no window, and on the Mac quitting must reach them after every window has closed.
final class NovelForgeAppDelegate: NSObject {
  static let pushDeadline = Duration.seconds(25)
  static let quitDeadline = Duration.seconds(3)

  let vault = VaultModel(locate: { () throws(VaultOpenError) -> StoreLocation in try VaultOpener.appLocation() })
  let sync = SyncRuntimes.live()
  let ai = AIServices.live()
  let jobs = JobRuntimes(host: JobRunHosts.system())
  let retrieval = RetrievalRuntimes()
  #if os(macOS)
    private(set) lazy var worker = WorkerModel.live(sync: sync)
  #endif
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

  private func observe(_ name: Notification.Name, in center: NotificationCenter = .default, _ handle: @escaping @MainActor () async -> Void) {
    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in await handle() } })
  }
}

#if os(macOS)
  extension NovelForgeAppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      observe(NSWindow.willCloseNotification) { await UnsavedWork.shared.flushAll(within: .seconds(3)) }
      observe(NSApplication.didBecomeActiveNotification) { [sync, worker] in
        worker.refreshLoginItem()
        await sync.activated()
      }
      observe(NSWindow.didBecomeMainNotification) { [sync] in await sync.activated() }
      observe(NSWorkspace.didWakeNotification, in: NSWorkspace.shared.notificationCenter) { [sync, worker] in
        guard worker.isOn else { return }
        await sync.activated()
      }
      if SyncCapabilities.current.receivesPushes { NSApplication.shared.registerForRemoteNotifications() }
      worker.follow(jobs)
      guard worker.isOn else { return }
      Task {
        await worker.launched()
        await runWithoutWindow()
      }
    }

    /// Worker mode keeps the process running in the menu bar with no window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      false
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
      Task { _ = await syncAfterPush() }
    }

    /// A worker Mac launched with no window, as at login, starts what a window would: its jobs, their retrieval index and the models routing reads.
    private func runWithoutWindow() async {
      await openAndSync()
      guard let store = vault.store else { return }
      await ai.loadOpenRouterModelsIfKeyed()
      await jobs.launch(store, services: ai, trustedClock: vault.trustedClock)
      await retrieval.launch(store, embedders: ai.embedders)
    }

    /// The job runtime starts nothing more, and a run going here ends as a crash would but releases its lease first; the upload after it tells other
    /// devices, so one of them may take the job over at once rather than after the lease lapses.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      let runtime = jobs.active
      guard UnsavedWork.shared.hasWork || sync.status != .off || runtime != nil else { return .terminateNow }
      Task { @MainActor in
        if let runtime { _ = await SyncBackgroundWork.bounded(Self.quitDeadline) { await runtime.stopBeforeQuitting() } }
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
