import Observation
import SwiftUI

@MainActor
@Observable
final class CatalogModel {
  let launch: CatalogLaunchConfiguration
  var selection: CatalogPage?
  var appearance: CatalogAppearance
  var columnVisibility: NavigationSplitViewVisibility

  init(launch: CatalogLaunchConfiguration) {
    self.launch = launch
    selection = launch.page
    appearance = launch.appearance ?? .system
    columnVisibility = launch.page == nil ? .automatic : .detailOnly
  }
}
