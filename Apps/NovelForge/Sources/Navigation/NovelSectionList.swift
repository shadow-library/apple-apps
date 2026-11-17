import ShadowDesignSystem
import SwiftUI

struct NovelSectionList: View {
  @Bindable var navigator: NovelNavigator

  var body: some View {
    List(NovelSection.allCases, selection: $navigator.section) { section in
      ShadowSidebarLabel(Text(section.title), systemImage: section.systemImage)
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
  }
}
