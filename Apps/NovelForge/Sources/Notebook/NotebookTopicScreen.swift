import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct NotebookTopicScreen: View {
  let model: NotebookModel
  let topic: NotebookTopic

  var body: some View {
    content
      .navigationTitle(Text(topic.title))
      .toolbar { if let kind = topic.authorKind { NotebookAddToolbar(model: model, kind: kind) } }
  }

  @ViewBuilder
  private var content: some View {
    if topic == .notes {
      NotebookNotesScreen(notes: model.notes)
    } else {
      NotebookLoaded(model: model) { snapshot in entries(snapshot) }
    }
  }

  private func entries(_ snapshot: NotebookSnapshot) -> some View {
    let visibility = model.visibility(of: topic)
    let shown = snapshot.entries(in: topic, showing: visibility)
    let earlier = snapshot.earlierCount(in: topic)
    return VStack(spacing: 0) {
      if earlier > 0 { visibilityPicker(earlier: earlier) }
      if shown.isEmpty {
        empty(earlier: earlier)
      } else {
        List {
          Section {
            ForEach(shown, id: \.id) { entry in
              NavigationLink(value: NotebookRoute.entry(entry.id)) { NotebookEntryRow(entry: entry) }.shadowListRowChrome()
            }
          }
          if topic == .decisions { passedOver(snapshot.passedOver()) }
        }
        .shadowListStyle()
      }
    }
  }

  private func visibilityPicker(earlier: Int) -> some View {
    Picker(
      selection: Binding(get: { model.visibility(of: topic) }, set: { model.setVisibility($0, of: topic) })
    ) {
      Text("Active", tableName: "Notebook").tag(NotebookVisibility.active)
      Text("With \(earlier) earlier", tableName: "Notebook").tag(NotebookVisibility.all)
    } label: {
      Text("Show", tableName: "Notebook")
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(Spacing.space3)
  }

  private func empty(earlier: Int) -> some View {
    ShadowContentUnavailable(Text("Nothing here yet", tableName: "Notebook"), systemImage: topic.systemImage, message: emptyMessage(earlier: earlier)) {
      if let kind = topic.authorKind {
        Button {
          model.present(.add(kind))
        } label: {
          Text("Add Entry…", tableName: "Notebook")
        }
      }
    }
    .fillingSurface()
  }

  private func emptyMessage(earlier: Int) -> Text {
    if earlier > 0 { return Text("Only earlier entries remain. Show them to see what was replaced or withdrawn.", tableName: "Notebook") }
    if topic == .decisions { return Text("Decisions are recorded as you settle things with Novel Forge. You can rewrite one once it appears.", tableName: "Notebook") }
    return Text(topic.summary)
  }

  @ViewBuilder
  private func passedOver(_ items: [NotebookSections.PassedOver]) -> some View {
    if !items.isEmpty {
      Section {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          ShadowListRow(title: Text(verbatim: item.alternative), caption: Text("Passed over for \(item.topic)", tableName: "Notebook"))
        }
      } header: {
        Text("Passed over", tableName: "Notebook")
      }
    }
  }
}
