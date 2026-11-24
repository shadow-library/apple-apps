import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Waits for the vault's modules, then gives iPhone the tab bar and iPad at regular width and the Mac the sidebar, both built from those modules, which
/// every screen below reads from the environment.
struct MemoirShell: View {
  let context: MemoirScreenContext
  @State private var modules = MemoirModules()

  var body: some View {
    Group {
      switch modules.standing {
      case .reading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(ShadowColor.surfaceApp)
      case .read(let selection): MemoirShellLayout(context: context, modules: selection)
      }
    }
    .environment(modules)
    .task { await modules.run(stores: context.stores) }
  }
}

private struct MemoirShellLayout: View {
  let context: MemoirScreenContext
  let modules: ModuleSelection
  @State private var navigator: MemoirNavigator
  @Environment(\.horizontalSizeClass) private var sizeClass

  init(context: MemoirScreenContext, modules: ModuleSelection) {
    self.context = context
    self.modules = modules
    _navigator = State(initialValue: MemoirNavigator(modules: modules))
  }

  var body: some View {
    Group {
      switch MemoirLayout(sizeClass: sizeClass) {
      case .sidebar: MemoirSidebarShell(context: context, navigator: navigator)
      case .tabs: MemoirTabShell(context: context, navigator: navigator)
      }
    }
    .onChange(of: MemoirLayout(sizeClass: sizeClass), initial: true) { _, layout in navigator.layout = layout }
    .onChange(of: modules) { _, modules in navigator.modules = modules }
  }
}

#Preview("Every module") {
  if let context = try? MemoirScreenContext.inMemory() {
    MemoirShell(context: context).environment(SyncRuntimes(identity: .memoir, factory: nil)).shadowTheme()
  }
}

#Preview("Money only") {
  @Previewable @State var context: MemoirScreenContext?
  Group {
    if let context { MemoirShell(context: context) } else { ProgressView() }
  }
  .environment(SyncRuntimes(identity: .memoir, factory: nil))
  .shadowTheme()
  .task {
    guard context == nil, let preview = try? MemoirScreenContext.inMemory(), let euro = CurrencyCode("EUR") else { return }
    try? await preview.writer.write { _, transaction in
      _ = try AccountSettingsRecord(
        defaultCurrency: euro, enabledCurrencies: [euro], moduleHero: false, moduleQuests: false, moduleMoney: true, moduleJournal: false, moduleMeals: false,
        moduleBody: false
      ).create(in: &transaction)
    }
    context = preview
  }
}
