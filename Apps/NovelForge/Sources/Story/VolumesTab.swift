import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension VolumeState {
  var pill: StatusPill {
    switch self {
    case .active: StatusPill(title: Text("Active", tableName: "Story"), tone: .accent)
    case .goalMet: StatusPill(title: Text("Goal met", tableName: "Story"), tone: .success)
    case .notStarted: StatusPill(title: Text("Not started", tableName: "Story"), tone: .neutral)
    }
  }
}

struct VolumesTab: View {
  let model: StoryModel
  let structure: StoryStructure

  var body: some View {
    switch structure.volumes {
    case .unavailable(let faults):
      StoryUnavailable(faults: faults)
    case .available(let section):
      if section.items.isEmpty && model.restorable.isEmpty {
        ShadowContentUnavailable(
          Text("No volumes yet", tableName: "Story"), systemImage: "books.vertical",
          message: Text("Volumes split the novel into arcs. The first one without a met goal is the one you are writing.", tableName: "Story")
        ) {
          Button {
            model.present(.newVolume)
          } label: {
            Text("New Volume", tableName: "Story")
          }
        }
        .fillingSurface()
      } else {
        list(section)
      }
    }
  }

  private func list(_ section: StructureSection<VolumeItem>) -> some View {
    List {
      if section.unreadable > 0 { unreadableNote(section.unreadable) }
      Section {
        ForEach(Array(section.items.enumerated()), id: \.element.record.volume) { index, item in
          NavigationLink(value: StoryRoute.volume(item.record.volume)) {
            VolumeRow(item: item, position: index + 1)
          }
          .shadowListRowChrome()
          .contextMenu { VolumeActions(model: model, item: item, canMoveUp: index > 0, canMoveDown: index < section.items.count - 1) }
        }
        .onMove { source, destination in Task { await model.moveVolumes(from: source, to: destination) } }
      }
      RemovedItemsSection(model: model, items: model.restorable.filter { if case .volume = $0 { true } else { false } })
    }
    .shadowListStyle()
    .shadowScreen(.root)
  }

  private func unreadableNote(_ count: Int) -> some View {
    ShadowCallout(Text("\(count) volumes cannot be read by this version", tableName: "Story"), intent: .warning)
  }
}

struct VolumeRow: View {
  let item: VolumeItem
  let position: Int

  var body: some View {
    ShadowListRow(
      title: Text(verbatim: item.displayName), subtitle: item.record.objective?.storyNonBlank.map { Text(verbatim: $0) },
      caption: item.hasTitle ? Text(verbatim: item.record.volume) : nil,
      leading: { Text(verbatim: "\(position)").shadowFont(.headline).foregroundStyle(ShadowColor.textSecondary).monospacedDigit() },
      trailing: { item.state.pill }
    )
  }
}

struct VolumeActions: View {
  let model: StoryModel
  let item: VolumeItem
  let canMoveUp: Bool
  let canMoveDown: Bool

  var body: some View {
    if item.state == .active {
      Button {
        model.confirmingGoalMet = item.record.volume
      } label: {
        Label(title: { Text("Mark Goal Met…", tableName: "Story") }, icon: { Image(systemName: "checkmark.seal") })
      }
    }
    Button {
      model.present(.editVolume(item.record.volume))
    } label: {
      Label(title: { Text("Edit…", tableName: "Story") }, icon: { Image(systemName: "pencil") })
    }
    Button {
      Task { await model.moveVolume(item.record.volume, by: -1) }
    } label: {
      Label(title: { Text("Move Up", tableName: "Story") }, icon: { Image(systemName: "arrow.up") })
    }
    .disabled(!canMoveUp)
    Button {
      Task { await model.moveVolume(item.record.volume, by: 1) }
    } label: {
      Label(title: { Text("Move Down", tableName: "Story") }, icon: { Image(systemName: "arrow.down") })
    }
    .disabled(!canMoveDown)
    Divider()
    Button(role: .destructive) {
      Task { await model.removeVolume(item) }
    } label: {
      Label(title: { Text("Remove", tableName: "Story") }, icon: { Image(systemName: "trash") })
    }
  }
}

struct VolumeDetailView: View {
  let model: StoryModel
  let key: String

  var body: some View {
    StoryLoaded(model: model) { structure in
      switch structure.volumes {
      case .unavailable(let faults): StoryUnavailable(faults: faults)
      case .available(let section):
        if let index = section.items.firstIndex(where: { $0.record.volume == key }) {
          details(section.items[index], position: index + 1, count: section.items.count)
        } else {
          StoryNotFound(title: Text("Volume not found", tableName: "Story"))
        }
      }
    }
    .navigationTitle(Text(verbatim: model.structure.value?.volume(key)?.displayName ?? key))
    .storyPresentations(model)
  }

  private func details(_ item: VolumeItem, position: Int, count: Int) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        HStack(spacing: Spacing.space3) {
          Text("Volume \(position)", tableName: "Story").shadowFont(.headline).foregroundStyle(ShadowColor.textSecondary)
          item.state.pill
        }
        Text(verbatim: item.displayName).shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
        if item.hasTitle { Text(verbatim: item.record.volume).shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary).textSelection(.enabled) }
        block(Text("Goal", tableName: "Story"), item.record.objective)
        block(Text("Summary", tableName: "Story"), item.record.body)
        if item.state == .active {
          Button {
            model.confirmingGoalMet = item.record.volume
          } label: {
            Text("Mark Goal Met…", tableName: "Story")
          }
        }
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.pushed)
    .toolbar {
      ToolbarItemGroup {
        Menu {
          VolumeActions(model: model, item: item, canMoveUp: position > 1, canMoveDown: position < count)
        } label: {
          Label(title: { Text("Actions", tableName: "Story") }, icon: { Image(systemName: "ellipsis.circle") })
        }
        .shadowBarItem()
      }
    }
  }

  @ViewBuilder
  private func block(_ title: Text, _ text: String?) -> some View {
    if let text = text?.storyNonBlank {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        title.shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        Text(verbatim: text).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
      }
    }
  }
}

struct VolumeFormSheet: View {
  let model: StoryModel
  let editing: VolumeItem?
  @State private var key: String
  @State private var title: String
  @State private var objective: String
  @State private var summary: String

  init(model: StoryModel, editing: VolumeItem?) {
    self.model = model
    self.editing = editing
    let taken = model.structure.value?.volumes.value?.items.map(\.record.volume) ?? []
    _key = State(initialValue: editing?.record.volume ?? StoryKey.unused(prefix: "volume", taken: taken))
    _title = State(initialValue: editing?.record.title ?? "")
    _objective = State(initialValue: editing?.record.objective ?? "")
    _summary = State(initialValue: editing?.record.body ?? "")
  }

  var body: some View {
    StoryFormScaffold(
      heading: editing == nil ? LocalizedStringResource("New Volume", table: "Story") : LocalizedStringResource("Edit Volume", table: "Story"),
      confirmTitle: editing == nil ? Text("Create", tableName: "Story") : Text("Save", tableName: "Story"), canSubmit: StoryKey.isValid(key) && (editing == nil || hasChanges),
      hasChanges: hasChanges,
      submit: submit
    ) {
      StoryField(Text("Key", tableName: "Story"), hint: Text("A short unique name, without spaces. It cannot change later.", tableName: "Story")) {
        TextField(text: $key) { Text("Key", tableName: "Story") }.shadowField().disabled(editing != nil)
      }
      StoryField(Text("Title", tableName: "Story")) {
        TextField(text: $title, prompt: Text("Optional", tableName: "Story")) { Text("Title", tableName: "Story") }.shadowField()
      }
      StoryField(Text("Goal", tableName: "Story"), hint: Text("What this volume must achieve before the next one begins.", tableName: "Story")) {
        ShadowTextEditor(text: $objective, placeholder: Text("Optional", tableName: "Story"), minHeight: 72, maxHeight: 160) { _ in Text(verbatim: "") }
      }
      StoryField(Text("Summary", tableName: "Story")) {
        ShadowTextEditor(text: $summary, placeholder: Text("Optional", tableName: "Story"), minHeight: 96, maxHeight: 240) { _ in Text(verbatim: "") }
      }
    }
  }

  private var hasChanges: Bool {
    guard let editing else { return !title.isEmpty || !objective.isEmpty || !summary.isEmpty }
    return title != (editing.record.title ?? "") || objective != (editing.record.objective ?? "") || summary != (editing.record.body ?? "")
  }

  private func submit() async throws {
    if editing == nil {
      try await model.createVolume(key: key, title: title, objective: objective, body: summary)
    } else {
      try await model.editVolume(key: key, title: title, objective: objective, body: summary)
    }
  }
}
