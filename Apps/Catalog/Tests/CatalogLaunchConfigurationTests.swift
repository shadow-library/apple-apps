import Foundation
import SwiftUI
import Testing

@testable import Catalog

@Suite("CatalogLaunchConfiguration")
struct CatalogLaunchConfigurationTests {
  @Test("should parse component and appearance")
  func parsesBoth() {
    let launch = CatalogLaunchConfiguration(arguments: ["Catalog", "-component", "OneTimeCodeField", "-appearance", "dark"])
    #expect(launch.page == .component(.oneTimeCodeField))
    #expect(launch.appearance == .dark)
    #expect(launch.isAutomated)
  }

  @Test("should parse the tokens page")
  func parsesTokens() {
    #expect(CatalogLaunchConfiguration(arguments: ["-component", "Tokens"]).page == .tokens)
  }

  @Test("should not be automated without arguments")
  func ignoresEmpty() {
    let launch = CatalogLaunchConfiguration(arguments: ["Catalog"])
    #expect(launch.page == nil)
    #expect(launch.appearance == nil)
    #expect(!launch.isAutomated)
  }

  @Test("should fall back to the list for an unknown component")
  func unknownComponent() {
    let launch = CatalogLaunchConfiguration(arguments: ["-component", "Nope", "-appearance", "light"])
    #expect(launch.page == nil)
    #expect(launch.appearance == .light)
  }

  @Test("should ignore an unknown or missing appearance value")
  func invalidAppearance() {
    #expect(CatalogLaunchConfiguration(arguments: ["-appearance", "sepia"]).appearance == nil)
    #expect(CatalogLaunchConfiguration(arguments: ["-appearance", "system"]).appearance == nil)
    #expect(CatalogLaunchConfiguration(arguments: ["-appearance"]).appearance == nil)
  }

  @Test("should not consume another flag as a value")
  func flagAsValue() {
    let launch = CatalogLaunchConfiguration(arguments: ["-component", "-appearance", "dark"])
    #expect(launch.page == nil)
    #expect(launch.appearance == .dark)
  }

  @Test("should accept a case-insensitive appearance and use the last occurrence")
  func lastWins() {
    let launch = CatalogLaunchConfiguration(arguments: ["-appearance", "light", "-appearance", "DARK"])
    #expect(launch.appearance == .dark)
  }

  @Test("should parse the snapshot path and treat it as automated")
  func parsesSnapshot() {
    let launch = CatalogLaunchConfiguration(arguments: ["-component", "Glass", "-snapshot", "/tmp/shots/Glass-dark.png"])
    #expect(launch.snapshotURL == URL(filePath: "/tmp/shots/Glass-dark.png"))
    #expect(launch.isAutomated)
    #expect(CatalogLaunchConfiguration(arguments: ["-snapshot"]).snapshotURL == nil)
  }

  @Test("should detect the list-components flag")
  func parsesListComponents() {
    #expect(CatalogLaunchConfiguration(arguments: ["Catalog", "-list-components"]).listsComponents)
    #expect(!CatalogLaunchConfiguration(arguments: ["Catalog"]).listsComponents)
  }

  @Test("should parse the scroll fraction")
  func parsesScroll() {
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "0.5"]).scrollFraction == 0.5)
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "0"]).scrollFraction == 0)
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "1"]).scrollFraction == 1)
  }

  @Test("should clamp a scroll fraction above one")
  func clampsScroll() {
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "7"]).scrollFraction == 1)
  }

  @Test("should ignore an invalid scroll fraction")
  func invalidScroll() {
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "middle"]).scrollFraction == nil)
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "nan"]).scrollFraction == nil)
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "inf"]).scrollFraction == nil)
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "-0.5"]).scrollFraction == nil)
  }

  @Test("should leave the scroll fraction unset when missing")
  func missingScroll() {
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll"]).scrollFraction == nil)
    #expect(CatalogLaunchConfiguration(arguments: ["-scroll", "-appearance", "dark"]).scrollFraction == nil)
    #expect(CatalogLaunchConfiguration(arguments: ["Catalog"]).scrollFraction == nil)
  }

  @Test("should start the model detail-only when a component is requested")
  @MainActor
  func modelColumns() {
    let deepLinked = CatalogModel(launch: CatalogLaunchConfiguration(arguments: ["-component", "Glass"]))
    deepLinked.openLaunchPage()
    #expect(deepLinked.selection == .component(.glass))
    #expect(deepLinked.columnVisibility == .detailOnly)
    let plain = CatalogModel(launch: CatalogLaunchConfiguration(arguments: []))
    #expect(plain.selection == nil)
    #expect(plain.columnVisibility == .automatic)
  }
}
