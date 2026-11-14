import SwiftUI
import Testing

@testable import Catalog

@MainActor
@Suite("CatalogModel")
struct CatalogModelTests {
  @Test("should defer the launch page until the shell has appeared")
  func defersLaunchPage() {
    let model = CatalogModel(launch: CatalogLaunchConfiguration(page: .component(.list)))
    #expect(model.selection == nil)
    model.openLaunchPage()
    #expect(model.selection == .component(.list))
  }

  @Test("should open the launch page only once")
  func opensLaunchPageOnce() {
    let model = CatalogModel(launch: CatalogLaunchConfiguration(page: .component(.tabBar)))
    model.openLaunchPage()
    #expect(model.demo == .tabBar)
    model.closeDemo()
    model.openLaunchPage()
    #expect(model.demo == nil)
  }

  @Test("should present full-bleed components as a demo instead of selecting them")
  func presentsDemo() {
    let model = CatalogModel(launch: CatalogLaunchConfiguration())
    model.selection = .component(.button)
    model.sidebarSelection = .component(.navigationBar)
    #expect(model.demo == .navigationBar)
    #expect(model.selection == .component(.button))
  }

  @Test("should select scrolling and list pages in the detail column")
  func selectsPages() {
    let model = CatalogModel(launch: CatalogLaunchConfiguration())
    model.sidebarSelection = .component(.list)
    #expect(model.selection == .component(.list))
    #expect(model.demo == nil)
  }

  @Test("should keep the split view automatic when launched into a demo")
  func automaticColumnsForDemo() {
    #expect(CatalogModel(launch: CatalogLaunchConfiguration(page: .component(.sidebar))).columnVisibility == .automatic)
  }
}
