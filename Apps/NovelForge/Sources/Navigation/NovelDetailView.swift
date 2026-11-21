import SwiftUI

struct NovelDetailView: View {
  let navigator: NovelNavigator
  let readers: NovelReaders
  let section: NovelSection
  let context: NovelContext

  var body: some View {
    NavigationStack(path: navigator.path(for: section)) {
      root
    }
    .environment(navigator)
    .id(section)
  }

  private var root: some View {
    NovelSectionContent(section: section, readers: readers, context: context)
  }
}

struct NovelSectionContent: View {
  let section: NovelSection
  let readers: NovelReaders
  let context: NovelContext

  var body: some View {
    switch section {
    case .overview: OverviewView(context: context)
    case .reader: ReaderView(context: context, model: readers.model(for: context))
    case .story: StoryView(context: context)
    case .storyBible: StoryBibleView(context: context)
    case .notebook: NotebookView(context: context)
    case .chat: ChatView(context: context)
    }
  }
}
