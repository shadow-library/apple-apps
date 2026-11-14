import Testing

@testable import Catalog

@Suite("CatalogComponent")
struct CatalogComponentTests {
  private static let specFolders: Set<String> = [
    "AccountMenu", "Alert", "Avatar", "Badge", "Button", "Callout", "Card", "Chart", "ColorPicker", "CommandPalette", "ConfirmationDialog",
    "ContentUnavailable", "DatePicker", "DisclosureGroup", "FileImporter", "Glass", "IconButton", "Inspector", "iPadScreen", "iPhoneScreens",
    "LabeledContent", "List", "MacScreen", "Menu", "NavigationBar", "NotificationList", "OneTimeCodeField", "OutlineGroup", "Picker", "Popover",
    "ProgressView", "Rating", "RefreshControl", "SearchField", "SegmentedControl", "Sheet", "Sidebar", "Skeleton", "Slider", "SplitView", "Statistic",
    "Stepper", "Steps", "SwipeActions", "TabBar", "Table", "Tag", "TextEditor", "TextField", "Timeline", "Toast", "Toggle", "TokenField", "Toolbar",
  ]

  @Test("should have a case for every spec component folder")
  func coversSpecFolders() {
    #expect(Set(CatalogComponent.allCases.map(\.id)) == Self.specFolders)
  }

  @Test("should have unique ids")
  func uniqueIds() {
    #expect(Set(CatalogComponent.allCases.map(\.id)).count == CatalogComponent.allCases.count)
    #expect(Set(CatalogPage.all.map(\.id)).count == CatalogPage.all.count)
  }

  @Test("should have a title and symbol for every component")
  func hasMetadata() {
    for component in CatalogComponent.allCases {
      #expect(!component.title.isEmpty)
      #expect(!component.systemImage.isEmpty)
    }
  }

  @Test("should never assign a component to the foundations group")
  func foundationsIsReserved() {
    #expect(CatalogComponent.allCases.allSatisfy { $0.group != .foundations })
  }

  @Test("should list every page in exactly one group, in sidebar order")
  func groupsPartitionPages() {
    let grouped = CatalogGroup.allCases.flatMap(\.pages)
    #expect(grouped == CatalogPage.all)
    #expect(CatalogGroup.allCases.map(\.title) == ["Foundations", "Glass", "Actions", "Inputs", "Navigation", "Presentation", "Status and feedback", "Data", "Screens"])
    #expect(CatalogGroup.foundations.pages == [.tokens])
  }

  @Test("should place the screens components in the screens group")
  func screensGroup() {
    #expect(CatalogGroup.screens.pages == [.component(.iPhoneScreens), .component(.iPadScreen), .component(.macScreen)])
  }

  @Test("should present chrome-owning components full bleed")
  func fullBleedLayout() {
    #expect(CatalogComponent.tabBar.layout == .fullBleed)
    #expect(CatalogComponent.macScreen.layout == .fullBleed)
    #expect(CatalogComponent.button.layout == .scroll)
  }

  @Test("should let list components own their scroll view")
  func listLayout() {
    for component in [CatalogComponent.list, .swipeActions, .refreshControl, .notificationList, .outlineGroup] {
      #expect(component.layout == .list)
    }
  }

  @Test("should resolve page ids case-insensitively and reject unknown ids")
  func pageLookup() {
    #expect(CatalogPage(id: "TabBar") == .component(.tabBar))
    #expect(CatalogPage(id: "tabbar") == .component(.tabBar))
    #expect(CatalogPage(id: "Tokens") == .tokens)
    #expect(CatalogPage(id: "Nope") == nil)
    #expect(CatalogPage(id: "") == nil)
  }
}
