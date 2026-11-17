import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct NotebookHome: View {
  let model: NotebookModel

  var body: some View {
    NotebookLoaded(model: model) { snapshot in
      VStack(spacing: Spacing.space3) {
        VStack(spacing: Spacing.space3) {
          if snapshot.unreadable > 0 { UnreadableCallout(count: snapshot.unreadable) }
          if isEmpty(snapshot) {
            ShadowCallout(
              Text("Your Notebook is empty", tableName: "Notebook"),
              message: Text("Decisions, directions and the ideas you turn down are collected here as you work.", tableName: "Notebook"), systemImage: "note.text")
          }
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.top, Spacing.space3)
        List {
          ForEach(NotebookTopic.allCases) { topic in
            NavigationLink(value: NotebookRoute.topic(topic)) { row(topic, snapshot) }.shadowListRowChrome()
          }
        }
        .shadowListStyle()
      }
    }
    .navigationTitle(Text(NovelSection.notebook.title))
    .toolbar { NotebookAddToolbar(model: model, kind: .direction) }
  }

  private func isEmpty(_ snapshot: NotebookSnapshot) -> Bool {
    NotebookTopic.allCases.allSatisfy { snapshot.activeCount(in: $0) + snapshot.earlierCount(in: $0) == 0 }
  }

  private func row(_ topic: NotebookTopic, _ snapshot: NotebookSnapshot) -> some View {
    let active = snapshot.activeCount(in: topic)
    let earlier = snapshot.earlierCount(in: topic)
    return ShadowListRow(
      title: Text(topic.title), subtitle: Text(topic.summary), caption: earlier > 0 ? Text("\(earlier) earlier", tableName: "Notebook") : nil,
      value: topic == .notes ? nil : Text(verbatim: active.formatted()), accessory: .chevron
    ) {
      ShadowSymbolTile(systemImage: topic.systemImage)
    }
  }
}

struct UnreadableCallout: View {
  let count: Int

  var body: some View {
    ShadowCallout(
      Text("\(count) entries cannot be read", tableName: "Notebook"),
      message: Text("They were written by a newer version of Novel Forge. Update the app to see them.", tableName: "Notebook"), intent: .warning)
  }
}

struct NotebookAddToolbar: ToolbarContent {
  let model: NotebookModel
  let kind: LedgerEntryKind

  var body: some ToolbarContent {
    ToolbarItem {
      Button {
        model.present(.add(kind))
      } label: {
        Label(title: { Text("Add Entry…", tableName: "Notebook") }, icon: { Image(systemName: "plus") })
      }
      .shadowBarItem()
    }
  }
}
