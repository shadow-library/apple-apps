import Foundation
import MemoirCore

/// The modules a place needs: any one of them on shows it.
enum MemoirModuleRequirement: Hashable, Sendable {
  case always
  case anyOf(Set<MemoirModule>)

  static func module(_ module: MemoirModule) -> Self { .anyOf([module]) }

  /// Reflection reads every module's data, so it shows while any module is on.
  static let anyModule = Self.anyOf(Set(MemoirModule.allCases))

  func isMet(by selection: ModuleSelection) -> Bool {
    switch self {
    case .always: true
    case .anyOf(let modules): !selection.modules.isDisjoint(with: modules)
    }
  }
}

/// The sidebar sections, tabs, roots and toolbars a module selection shows. A tab shows while its root does (Log while any capture screen does); what
/// a hidden tab pushed moves to the first tab shown, so Reflect and Settings stay reachable without Today. Log's root is its only capture screen when
/// one shows, else the list of them.
struct MemoirNavigationMap: Hashable, Sendable {
  let modules: ModuleSelection
  let destinations: [MemoirDestination]
  let tabs: [MemoirTab]

  init(_ modules: ModuleSelection) {
    self.modules = modules
    let destinations = MemoirDestination.allCases.filter { $0.requirement.isMet(by: modules) }
    self.destinations = destinations
    tabs = MemoirTab.allCases.filter { tab in
      tab.root.map(destinations.contains) ?? destinations.contains { $0.tab == tab }
    }
    assert(!tabs.isEmpty, "a valid selection shows a tab")
  }

  static let all = MemoirNavigationMap(.all)

  func shows(_ destination: MemoirDestination) -> Bool { destinations.contains(destination) }

  func shows(_ route: MemoirRoute) -> Bool { route.requirement.isMet(by: modules) }

  func shows(tab: MemoirTab) -> Bool { tabs.contains(tab) }

  var sections: [MemoirSection] { MemoirSection.allCases.filter { !destinations(in: $0).isEmpty } }

  func destinations(in section: MemoirSection) -> [MemoirDestination] { destinations.filter { $0.section == section } }

  var showsTabBar: Bool { tabs.count > 1 }

  var firstDestination: MemoirDestination { destinations.first ?? .settings }

  var firstTab: MemoirTab { tabs.first ?? .log }

  func tab(of destination: MemoirDestination) -> MemoirTab {
    shows(tab: destination.tab) ? destination.tab : firstTab
  }

  func root(of tab: MemoirTab) -> MemoirDestination? {
    if let root = tab.root { return root }
    let capture = destinations.filter { $0.tab == tab }
    return capture.count == 1 ? capture[0] : nil
  }

  /// Every destination reached from the tab's root: listed by a root that lists (`listed(in:)`), the rest from its toolbar.
  func pushed(in tab: MemoirTab) -> [MemoirDestination] {
    let root = root(of: tab)
    return destinations.filter { self.tab(of: $0) == tab && $0 != root }
  }

  func listed(in tab: MemoirTab) -> [MemoirDestination] {
    guard root(of: tab) == nil else { return [] }
    return pushed(in: tab).filter { $0.tab == tab }
  }

  /// The root's toolbar: a section's destinations share one menu, a lone destination is its own button.
  func toolbar(of tab: MemoirTab) -> [MemoirToolbarEntry] {
    let listed = listed(in: tab)
    let reached = pushed(in: tab).filter { !listed.contains($0) }
    return MemoirSection.allCases.compactMap { section in
      let destinations = reached.filter { $0.section == section }
      guard let first = destinations.first else { return nil }
      return destinations.count == 1 ? .link(first) : .menu(section, destinations)
    }
  }

  func title(of tab: MemoirTab) -> LocalizedStringResource {
    guard tab.root == nil, let root = root(of: tab) else { return tab.title }
    return root.title
  }

  func systemImage(of tab: MemoirTab) -> String {
    guard tab.root == nil, let root = root(of: tab) else { return tab.systemImage }
    return root.systemImage
  }

  func kept(_ path: [MemoirRoute]) -> [MemoirRoute] {
    guard let hidden = path.firstIndex(where: { !shows($0) }) else { return path }
    return Array(path[..<hidden])
  }

  func stack(_ path: [MemoirRoute], in tab: MemoirTab) -> [MemoirRoute] {
    let kept = kept(path)
    guard let root = root(of: tab), kept.first == .destination(root) else { return kept }
    return Array(kept.dropFirst())
  }
}
