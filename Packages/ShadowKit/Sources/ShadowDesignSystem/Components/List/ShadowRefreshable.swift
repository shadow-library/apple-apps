import SwiftUI

private struct ShadowRefreshableModifier: ViewModifier {
  let title: LocalizedStringKey
  let action: @MainActor () async -> Void

  @State private var isRefreshing = false

  func body(content: Content) -> some View {
    content
      .refreshable { await run() }
      #if os(macOS)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button {
              Task { await run() }
            } label: {
              Label(title, systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isRefreshing)
          }
        }
      #endif
  }

  private func run() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    await action()
  }
}

extension View {
  public func shadowRefreshable(_ title: LocalizedStringKey, action: @escaping @MainActor () async -> Void) -> some View {
    modifier(ShadowRefreshableModifier(title: title, action: action))
  }
}
