import ShadowDesignSystem
import ShadowStore
import SwiftUI

struct CompactNovelView: View {
  let navigator: NovelNavigator
  let readers: NovelReaders
  let context: NovelContext
  @State private var pending = PendingModel()
  @Environment(JobRuntimes.self) private var runtimes

  var body: some View {
    let standing = runtimes.existing(for: context.store)?.standing ?? .starting
    NavigationStack(path: navigator.compactBinding) {
      ChatView(context: context)
        .toolbar { CompactToolbar(navigator: navigator, waiting: pending.list(replica: context.store.replica, standing: standing).count) }
        .navigationDestination(for: CompactStop.self) { stop in destination(stop) }
    }
    .environment(navigator)
    .pendingObservation(pending, context: context)
  }

  @ViewBuilder
  private func destination(_ stop: CompactStop) -> some View {
    switch stop {
    case .section(let section): NovelSectionContent(section: section, readers: readers, context: context).environment(navigator)
    case .pending: PendingView(context: context, model: pending).environment(navigator)
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
        HStack(spacing: Spacing.space1) {
          Image(systemName: waiting > 0 ? "tray.full" : "tray")
          if waiting > 0 { ShadowBadge(count: waiting).fixedSize() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Waiting on you", tableName: "Navigation"))
      }
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
