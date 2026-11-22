import Foundation
import ShadowAppShell
import ShadowSyncRuntime
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Owns the vault, its day turns, its reminders, its sync and the AI services for the life of the process rather than of a window: a silent push may wake the app with no window to
/// open them, and on the Mac quitting must reach them after every window has closed.
final class MemoirAppDelegate: NSObject {
  static let pushDeadline = Duration.seconds(25)
  static let quitDeadline = Duration.seconds(3)

  let vault = MemoirVaultModel.live()
  let sync = SyncRuntimes.live(identity: .memoir)
  let ai = AIServices.memoir()
  let dayTurns = MemoirDayTurns()
  let reminders = ReminderScheduler.live()
  let health = MemoirHealthImports()
  lazy var insights = MemoirInsights(ai: ai, trustedClock: vault.trustedClock)
  lazy var deletion = MemoirVaultDeletion(vault: vault, sync: sync, dayTurns: dayTurns, reminders: reminders, insights: insights) { [weak self] in
    await self?.vaultChanged()
  }
  private var observers: [any NSObjectProtocol] = []

  /// Opens the vault if no window has yet, then follows its day and starts its sync; both wait for a call already in flight.
  func openAndSync() async {
    await vault.open()
    await vaultChanged()
  }

  func vaultChanged() async {
    dayTurns.follow(vault.opened)
    reminders.follow(vault.opened)
    guard let opened = vault.opened else { return await insights.follow(nil) }
    await sync.launch(MemoirSyncRoutes.vault(opened.stores), trustedClock: vault.trustedClock)
    await insights.follow(opened)
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
  extension MemoirAppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      MemoirExports.clearLeftovers()
      observe(NSApplication.didBecomeActiveNotification) { [sync] in await sync.activated() }
      observe(NSWindow.didBecomeMainNotification) { [sync] in await sync.activated() }
      if SyncCapabilities.current.receivesPushes { NSApplication.shared.registerForRemoteNotifications() }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
      Task { _ = await syncAfterPush() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      guard sync.status != .off else { return .terminateNow }
      Task { @MainActor in
        await sync.uploadBeforeQuitting(within: Self.quitDeadline)
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
    }
  }
#else
  extension MemoirAppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
      MemoirExports.clearLeftovers()
      observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [weak self] in
        guard let self else { return }
        await vault.protectedDataBecameAvailable()
        await vaultChanged()
        health.foregrounded(vault.opened)
      }
      if SyncCapabilities.current.receivesPushes { application.registerForRemoteNotifications() }
      return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
      await syncAfterPush() ? .newData : .noData
    }
  }
#endif
