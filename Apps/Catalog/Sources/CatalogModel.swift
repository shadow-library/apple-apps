import Observation
import SwiftUI

@MainActor
@Observable
final class CatalogModel {
  let launch: CatalogLaunchConfiguration
  var selection: CatalogPage?
  var demo: CatalogComponent?
  var appearance: CatalogAppearance
  var columnVisibility: NavigationSplitViewVisibility
  private var hasOpenedLaunchPage = false

  init(launch: CatalogLaunchConfiguration) {
    self.launch = launch
    appearance = launch.appearance ?? .system
    columnVisibility = launch.page == nil || launch.page?.layout == .fullBleed ? .automatic : .detailOnly
  }

  var sidebarSelection: CatalogPage? {
    get { selection }
    set { open(newValue) }
  }

  func open(_ page: CatalogPage?) {
    guard case .component(let component) = page, component.layout == .fullBleed else {
      selection = page
      return
    }
    demo = component
  }

  func closeDemo() {
    demo = nil
  }

  // A compact NavigationSplitView that is built with its detail already pushed never shows a List's large title; pushing after
  // the first layout pass behaves like a tap in the sidebar.
  func openLaunchPage() {
    guard !hasOpenedLaunchPage else { return }
    hasOpenedLaunchPage = true
    open(launch.page)
  }
}
