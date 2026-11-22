import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// iPhone gets the tab bar; iPad at regular width and the Mac get the sidebar.
struct MemoirShell: View {
  let stores: MemoirStores
  @State private var navigator = MemoirNavigator()
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    Group {
      switch MemoirLayout(sizeClass: sizeClass) {
      case .sidebar: MemoirSidebarShell(stores: stores, navigator: navigator)
      case .tabs: MemoirTabShell(stores: stores, navigator: navigator)
      }
    }
    .onChange(of: MemoirLayout(sizeClass: sizeClass), initial: true) { _, layout in navigator.layout = layout }
  }
}

#Preview {
  if let stores = try? MemoirStores.openInMemory() {
    MemoirShell(stores: stores).environment(SyncRuntimes(identity: .memoir, factory: nil)).shadowTheme()
  }
}
