import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// iPhone gets the tab bar; iPad at regular width and the Mac get the sidebar.
struct MemoirShell: View {
  let context: MemoirScreenContext
  @State private var navigator = MemoirNavigator()
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    Group {
      switch MemoirLayout(sizeClass: sizeClass) {
      case .sidebar: MemoirSidebarShell(context: context, navigator: navigator)
      case .tabs: MemoirTabShell(context: context, navigator: navigator)
      }
    }
    .onChange(of: MemoirLayout(sizeClass: sizeClass), initial: true) { _, layout in navigator.layout = layout }
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    MemoirShell(context: context).environment(SyncRuntimes(identity: .memoir, factory: nil)).shadowTheme()
  }
}
