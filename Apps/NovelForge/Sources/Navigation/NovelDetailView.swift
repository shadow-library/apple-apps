import SwiftUI

struct NovelDetailView: View {
  let navigator: NovelNavigator
  let section: NovelSection
  let context: NovelContext

  var body: some View {
    NavigationStack(path: navigator.path(for: section)) {
      root
    }
    .environment(navigator)
    .id(section)
  }

  @ViewBuilder
  private var root: some View {
    switch section {
    case .overview: OverviewView(context: context)
    case .reader: ReaderView(context: context)
    case .story: StoryView(context: context)
    case .storyBible: StoryBibleView(context: context)
    case .notebook: NotebookView(context: context)
    }
  }
}
