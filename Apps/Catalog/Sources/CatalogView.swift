import ShadowDesignSystem
import SwiftUI

struct CatalogView: View {
  @Bindable var model: CatalogModel

  var body: some View {
    NavigationSplitView(columnVisibility: $model.columnVisibility) {
      CatalogSidebar(selection: $model.selection)
    } detail: {
      CatalogDetail(page: model.selection, appearance: $model.appearance)
    }
  }
}

struct CatalogSidebar: View {
  @Binding var selection: CatalogPage?

  var body: some View {
    List(selection: $selection) {
      ForEach(CatalogGroup.allCases) { group in
        Section(group.title) {
          ForEach(group.pages) { page in
            Label(page.title, systemImage: page.systemImage).tag(page)
          }
        }
      }
    }
    .navigationTitle("Catalog")
  }
}

struct CatalogDetail: View {
  let page: CatalogPage?
  @Binding var appearance: CatalogAppearance

  #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var titleDisplayMode: ToolbarTitleDisplayMode {
      switch page?.layout {
      case .fullBleed: .inline
      case .list where horizontalSizeClass == .compact: .inline
      default: .automatic
      }
    }
  #endif

  var body: some View {
    Group {
      switch page {
      case .tokens: TokensPage()
      case .component(let component): component.page
      case nil: ContentUnavailableView("Select a component", systemImage: "square.grid.2x2")
      }
    }
    .navigationTitle(page?.title ?? "Catalog")
    #if !os(macOS)
      .toolbarTitleDisplayMode(titleDisplayMode)
    #endif
    .toolbar {
      if page != nil {
        ToolbarItem { AppearanceMenu(appearance: $appearance) }
      }
    }
    .accessibilityIdentifier(page.map { "catalog-page-\($0.id)" } ?? "catalog-empty")
  }
}

struct AppearanceMenu: View {
  @Binding var appearance: CatalogAppearance

  var body: some View {
    Menu {
      Picker("Appearance", selection: $appearance) {
        ForEach(CatalogAppearance.allCases) { option in
          Label(option.title, systemImage: option.systemImage).tag(option)
        }
      }
    } label: {
      Label("Appearance", systemImage: appearance.systemImage)
    }
  }
}

#Preview {
  CatalogView(model: CatalogModel(launch: CatalogLaunchConfiguration()))
}
