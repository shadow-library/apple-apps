import MemoirCore
import Observation

/// The place in the app, kept across layouts and module changes: the sidebar's screen with the details pushed above it, and each tab's stack. A layout
/// change carries the place over, so an iPad resize shows the same screen. Stacks drop every place the modules hide, so a stale link elsewhere pushes
/// nothing, and a module change falls back from a hidden screen or tab.
@MainActor
@Observable
final class MemoirNavigator {
  private(set) var map: MemoirNavigationMap
  var selection: MemoirDestination {
    didSet { if selection != oldValue { detailPath = [] } }
  }
  var detailPath: [MemoirRoute] = [] {
    didSet { if map.kept(detailPath) != detailPath { detailPath = map.kept(detailPath) } }
  }
  var tab: MemoirTab
  var paths: [MemoirTab: [MemoirRoute]] = [:] {
    didSet { if kept(paths) != paths { paths = kept(paths) } }
  }
  /// Nil until the shell first reads its size class, which places nothing: the first layout opens at the first screen or tab.
  var layout: MemoirLayout? {
    didSet {
      guard let layout, let oldValue, layout != oldValue else { return }
      switch layout {
      case .tabs: enterTabs()
      case .sidebar: enterSidebar()
      }
    }
  }

  init(layout: MemoirLayout? = nil, modules: ModuleSelection = .all) {
    let map = MemoirNavigationMap(modules)
    self.map = map
    selection = map.firstDestination
    tab = map.firstTab
    self.layout = layout
  }

  var modules: ModuleSelection {
    get { map.modules }
    set {
      guard newValue != map.modules else { return }
      let old = map
      map = MemoirNavigationMap(newValue)
      fallBackInSidebar()
      fallBackInTabs(from: old)
    }
  }

  func push(_ destination: MemoirDestination, in tab: MemoirTab) {
    paths[tab, default: []].append(.destination(destination))
  }

  private func kept(_ paths: [MemoirTab: [MemoirRoute]]) -> [MemoirTab: [MemoirRoute]] {
    paths.filter { map.shows(tab: $0.key) }.mapValues(map.kept)
  }

  private func fallBackInSidebar() {
    if !map.shows(selection) { selection = map.firstDestination }
    detailPath = map.kept(detailPath)
  }

  /// The tab shown keeps its stack, with its old root pushed when Log's root changes under it; a hidden tab's stack moves to the tab holding its first
  /// screen, or the first tab opens at its root.
  private func fallBackInTabs(from old: MemoirNavigationMap) {
    let current = tab
    let stack = paths[current] ?? []
    if map.shows(tab: current) {
      let oldRoot = old.root(of: current).flatMap { map.shows($0) && $0 != map.root(of: current) ? $0 : nil }
      paths[current] = map.stack((oldRoot.map { [.destination($0)] } ?? []) + stack, in: current)
    } else if case .destination(let destination)? = map.kept(stack).first {
      tab = map.tab(of: destination)
      paths[tab] = map.stack(stack, in: tab)
    } else {
      tab = map.firstTab
    }
    for other in paths.keys where other != tab {
      paths[other] = map.stack(paths[other] ?? [], in: other)
    }
  }

  private func enterTabs() {
    tab = map.tab(of: selection)
    paths[tab] = (selection == map.root(of: tab) ? [] : [.destination(selection)]) + detailPath
  }

  private func enterSidebar() {
    let stack = paths[tab] ?? []
    guard let index = stack.lastIndex(where: { $0.destination != nil }), let destination = stack[index].destination else {
      selection = map.root(of: tab) ?? map.listed(in: tab).first ?? map.firstDestination
      detailPath = stack
      return
    }
    selection = destination
    detailPath = Array(stack[stack.index(after: index)...])
  }
}
