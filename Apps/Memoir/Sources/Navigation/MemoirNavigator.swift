import Observation

/// The place in the app, kept across layouts: the sidebar's screen with the details pushed above it, and each tab's stack. A layout change carries the
/// place over, so an iPad resize shows the same screen.
@MainActor
@Observable
final class MemoirNavigator {
  var selection: MemoirDestination = .today {
    didSet { if selection != oldValue { detailPath = [] } }
  }
  var detailPath: [MemoirRoute] = []
  var tab: MemoirTab = .today
  var paths: [MemoirTab: [MemoirRoute]] = [:]
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
    paths[tab, default: []].append(.destination(destination))
  }

  private func enterTabs() {
    tab = selection.tab
    paths[tab] = (selection == tab.root ? [] : [.destination(selection)]) + detailPath
  }

  private func enterSidebar() {
    let stack = paths[tab] ?? []
    guard let index = stack.lastIndex(where: { $0.destination != nil }), let destination = stack[index].destination else {
      selection = tab.root ?? tab.pushed.first ?? .today
      detailPath = stack
      return
    }
    selection = destination
    detailPath = Array(stack[stack.index(after: index)...])
  }
}
