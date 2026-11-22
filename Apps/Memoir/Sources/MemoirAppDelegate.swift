import Foundation
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Owns the vault for the life of the process rather than of a window, so later lifecycle work (sync, pushes, reminders) reaches it without one.
final class MemoirAppDelegate: NSObject {
  let vault = MemoirVaultModel.live()
  private var observers: [any NSObjectProtocol] = []

  fileprivate func followTheDay() {
    for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [vault] _ in Task { await vault.refreshDay() } })
    }
  }
}

#if os(macOS)
  extension MemoirAppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      followTheDay()
    }
  }
#else
  extension MemoirAppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
      followTheDay()
      return true
    }
  }
#endif
