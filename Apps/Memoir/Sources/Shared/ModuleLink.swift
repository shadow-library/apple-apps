import SwiftUI

/// A link to another area's screen, left out while the vault's modules hide that screen; without `MemoirModules` in the environment (an area's preview)
/// it always shows.
struct ModuleLink<Label: View>: View {
  let route: MemoirRoute
  let label: Label
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  init(_ route: MemoirRoute, @ViewBuilder label: () -> Label) {
    self.route = route
    self.label = label()
  }

  var body: some View {
    if modules?.shows(route) ?? true {
      NavigationLink(value: route) { label }
    }
  }
}
