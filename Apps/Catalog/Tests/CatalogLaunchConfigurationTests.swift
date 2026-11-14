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

  @Test("should start the model detail-only when a component is requested")
  @MainActor
  func modelColumns() {
    let deepLinked = CatalogModel(launch: CatalogLaunchConfiguration(arguments: ["-component", "Glass"]))
    #expect(deepLinked.selection == .component(.glass))
    #expect(deepLinked.columnVisibility == .detailOnly)
    let plain = CatalogModel(launch: CatalogLaunchConfiguration(arguments: []))
    #expect(plain.selection == nil)
    #expect(plain.columnVisibility == .automatic)
  }
}
