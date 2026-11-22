import Observation

/// The place in the app, kept across layouts: the sidebar's screen and each tab's stack. A layout change carries the place over, so an iPad resize
/// shows the same screen.
@MainActor
@Observable
final class MemoirNavigator {
  var selection: MemoirDestination = .today
  var tab: MemoirTab = .today
  var paths: [MemoirTab: [MemoirDestination]] = [:]
  var layout: MemoirLayout {
    didSet {
      guard layout != oldValue else { return }
      switch layout {
      case .tabs: enterTabs()
      case .sidebar: enterSidebar()
      }
    }
  }

  init(layout: MemoirLayout = .sidebar) {
    self.layout = layout
  }

  func push(_ destination: MemoirDestination, in tab: MemoirTab) {
    paths[tab, default: []].append(destination)
  }

  private func enterTabs() {
    tab = selection.tab
    paths[tab] = selection == tab.root ? [] : [selection]
  }

  private func enterSidebar() {
    selection = paths[tab]?.last ?? tab.root ?? tab.pushed.first ?? .today
  }
}
