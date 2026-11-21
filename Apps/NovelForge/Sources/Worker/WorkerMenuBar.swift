#if os(macOS)
  import AppKit
  import SwiftUI

  /// The menu-bar item shown while worker mode is on; the system draws the menu and its material.
  struct WorkerMenuBar: Scene {
    let worker: WorkerModel
    let tabs: SettingsTabs

    var body: some Scene {
      MenuBarExtra(isInserted: Binding(get: { worker.isOn }, set: { _ in })) {
        WorkerMenu(worker: worker, tabs: tabs)
      } label: {
        Label {
          Text("Novel Forge", tableName: "Worker")
        } icon: {
          Image(systemName: worker.status.isRunning ? "text.book.closed.fill" : "text.book.closed")
        }
      }
    }
  }

  private struct WorkerMenu: View {
    let worker: WorkerModel
    let tabs: SettingsTabs
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
      let status = worker.status
      status.title
      if let detail = status.detail { detail }
      Divider()
      Button {
        open()
      } label: {
        Text("Open Novel Forge", tableName: "Worker")
      }
      Button {
        tabs.selected = .worker
        NSApplication.shared.activate()
        openSettings()
      } label: {
        Text("Devices and Worker Settings…", tableName: "Worker")
      }
      Divider()
      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Text("Quit Novel Forge", tableName: "Worker")
      }
      .keyboardShortcut("q")
    }

    /// Brings a library window forward, opening one only when none is left.
    private func open() {
      NSApplication.shared.activate()
      let window = NSApplication.shared.windows.first { window in
        window.identifier?.rawValue.hasPrefix(NovelForgeApp.libraryWindow) == true && (window.isVisible || window.isMiniaturized)
      }
      guard let window else { return openWindow(id: NovelForgeApp.libraryWindow) }
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
  }
#endif
