import SwiftUI

#if os(macOS)
  import AppKit

  final class NovelForgeAppDelegate: NSObject, NSApplicationDelegate {
    private var closing: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
      closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
        Task { @MainActor in await UnsavedWork.shared.flushAll(within: .seconds(3)) }
      }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      guard UnsavedWork.shared.hasWork else { return .terminateNow }
      Task { @MainActor in
        await UnsavedWork.shared.flushAll(within: .seconds(3))
        sender.reply(toApplicationShouldTerminate: true)
      }
      return .terminateLater
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
