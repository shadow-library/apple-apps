import ShadowDesignSystem
import SwiftUI

struct CompactNovelView: View {
  let navigator: NovelNavigator
  let readers: NovelReaders
  let context: NovelContext
  @State private var badge = WaitingBadgeModel()

  var body: some View {
    NavigationStack(path: navigator.compactBinding) {
      ChatView(context: context)
        .toolbar { CompactToolbar(navigator: navigator, waiting: badge.count) }
        .navigationDestination(for: CompactStop.self) { stop in destination(stop) }
    }
    .environment(navigator)
    .task(id: context.novel) { await badge.observe(context) }
  }

  @ViewBuilder
  private func destination(_ stop: CompactStop) -> some View {
    switch stop {
    case .section(let section): NovelSectionContent(section: section, readers: readers, context: context).environment(navigator)
    case .pending: PendingView(context: context).environment(navigator)
    }
  }
}

private struct CompactToolbar: ToolbarContent {
  #if os(macOS)
    private static let placement = ToolbarItemPlacement.automatic
  #else
    private static let placement = ToolbarItemPlacement.bottomBar
  #endif

  static let more: [NovelSection] = [.story, .storyBible, .notebook, .overview]

  let navigator: NovelNavigator
  let waiting: Int

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: Self.placement) {
      Button {
        navigator.show(.reader)
      } label: {
        Label(title: { Text("Chapters", tableName: "Navigation") }, icon: { Image(systemName: "list.bullet") })
      }
      .shadowBarItem()
      Spacer()
      Button {
        navigator.push(CompactStop.pending)
      } label: {
        Label(title: { Text("Waiting on you", tableName: "Navigation") }, icon: { Image(systemName: "tray") })
      }
      .overlay(alignment: .topTrailing) { if waiting > 0 { ShadowBadge(count: waiting).offset(x: Spacing.space2, y: -Spacing.space2) } }
      .accessibilityValue(Text("\(waiting) waiting", tableName: "Navigation"))
      .shadowBarItem()
      Spacer()
      Menu {
        ForEach(Self.more) { section in
          Button {
            navigator.show(section)
          } label: {
            Label(title: { Text(section.title) }, icon: { Image(systemName: section.systemImage) })
          }
        }
      } label: {
        Label(title: { Text("More", tableName: "Navigation") }, icon: { Image(systemName: "ellipsis.circle") })
      }
      .shadowBarItem()
    }
  }
}
