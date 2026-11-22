import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct NovelSectionPlaceholder: View {
  let section: NovelSection

  init(_ section: NovelSection) {
    self.section = section
  }

  var body: some View {
    ShadowContentUnavailable(Text(section.title), systemImage: section.systemImage, message: Text("This section is not available yet.", tableName: "Navigation"))
      .fillingSurface()
      .navigationTitle(Text(section.title))
  }
}
