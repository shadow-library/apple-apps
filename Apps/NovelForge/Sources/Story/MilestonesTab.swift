import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension MilestoneState {
  var pill: StatusPill {
    switch self {
    case .reached: StatusPill(title: Text("Reached", tableName: "Story"), tone: .success)
    case .planned: StatusPill(title: Text("Planned", tableName: "Story"), tone: .accent)
    case .open: StatusPill(title: Text("Open", tableName: "Story"), tone: .neutral)
    }
  }
}

extension MilestoneKind {
  var title: Text {
    switch self {
    case .rank: Text("Rank", tableName: "Story")
    case .event: Text("Event", tableName: "Story")
    case .learnedFrom: Text("Learned from", tableName: "Story")
    case .custom: Text("Custom", tableName: "Story")
    }
  }
}

extension MilestoneItem {
  var chapterNote: Text? {
    switch state {
    case .reached: reachedChapter.map { Text("Reached in chapter \($0)", tableName: "Story") }
    case .planned: plannedChapter.map { Text("Planned for chapter \($0)", tableName: "Story") }
    case .open: nil
    }
  }

  var duplicateNote: Text? {
    guard !duplicateClaims.isEmpty else { return nil }
    return Text("Also claimed by \(duplicateClaims.count) chapters: \(duplicateClaims.map(String.init).formatted(.list(type: .and)))", tableName: "Story")
  }
}

struct MilestonesTab: View {
  let model: StoryModel
  let structure: StoryStructure

  var body: some View {
    switch structure.milestones {
    case .unavailable(let faults):
      StoryUnavailable(faults: faults)
    case .available(let section):
      if section.items.isEmpty && model.restorable.isEmpty {
        ShadowContentUnavailable(
          Text("No milestones yet", tableName: "Story"), systemImage: "flag",
          message: Text("Milestones mark story beats such as a rank earned or a secret learned. Chapter plans claim them.", tableName: "Story")
        ) {
          Button {
            model.present(.newMilestone)
          } label: {
            Text("New Milestone", tableName: "Story")
          }
        }
        .fillingSurface()
      } else {
        list(section)
      }
    }
  }

  private func list(_ section: StructureSection<MilestoneItem>) -> some View {
    List {
      if section.unreadable > 0 { ShadowCallout(Text("\(section.unreadable) milestones cannot be read by this version", tableName: "Story"), intent: .warning) }
      Section {
        ForEach(section.items, id: \.record.milestone) { item in
          NavigationLink(value: StoryRoute.milestone(item.record.milestone)) { MilestoneRow(item: item) }
            .shadowListRowChrome()
            .contextMenu { MilestoneActions(model: model, item: item) }
        }
      }
      RemovedItemsSection(model: model, items: model.restorable.filter { if case .milestone = $0 { true } else { false } })
    }
    .shadowListStyle()
    .shadowScreen(.root)
  }
}

struct MilestoneRow: View {
  let item: MilestoneItem

  var body: some View {
    ShadowListRow(
      title: Text(verbatim: item.record.label), subtitle: item.chapterNote, caption: item.duplicateNote,
      leading: { Image(systemName: "flag").foregroundStyle(ShadowColor.textSecondary) },
      trailing: {
        HStack(spacing: Spacing.space2) {
          if item.duplicateNote != nil { StatusPill(title: Text("Duplicate claim", tableName: "Story"), tone: .warning) }
          item.state.pill
        }
      })
  }
}

struct MilestoneActions: View {
  let model: StoryModel
  let item: MilestoneItem

  var body: some View {
    Button {
      model.present(.editMilestone(item.record.milestone))
    } label: {
      Label(title: { Text("Edit…", tableName: "Story") }, icon: { Image(systemName: "pencil") })
    }
    Divider()
    Button(role: .destructive) {
      Task { await model.removeMilestone(item) }
    } label: {
      Label(title: { Text("Remove", tableName: "Story") }, icon: { Image(systemName: "trash") })
    }
  }
}

struct MilestoneDetailView: View {
  let model: StoryModel
  let key: String

  var body: some View {
    StoryLoaded(model: model) { structure in
      switch structure.milestones {
      case .unavailable(let faults): StoryUnavailable(faults: faults)
      case .available:
        if let item = structure.milestone(key) {
          details(item)
        } else {
          StoryNotFound(title: Text("Milestone not found", tableName: "Story"))
        }
      }
    }
    .navigationTitle(Text(verbatim: model.structure.value?.milestone(key)?.record.label ?? key))
    .storyPresentations(model)
  }

  private func details(_ item: MilestoneItem) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        HStack(spacing: Spacing.space3) {
          item.record.kind.known.map { $0.title.shadowFont(.headline).foregroundStyle(ShadowColor.textSecondary) }
          item.state.pill
        }
        Text(verbatim: item.record.label).shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
        Text(verbatim: item.record.milestone).shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary).textSelection(.enabled)
        if let note = item.chapterNote { note.shadowFont(.body).foregroundStyle(ShadowColor.textSecondary) }
        if let subject = item.record.subject {
          Text("About \(model.entityName(subject))", tableName: "Story").shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
        }
        if let note = item.duplicateNote {
          ShadowCallout(
            Text("Claimed more than once", tableName: "Story"), message: note, intent: .warning, systemImage: "exclamationmark.triangle")
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
          MilestoneActions(model: model, item: item)
        } label: {
          Label(title: { Text("Actions", tableName: "Story") }, icon: { Image(systemName: "ellipsis.circle") })
        }
        .shadowBarItem()
      }
    }
  }
}

struct MilestoneFormSheet: View {
  let model: StoryModel
  let editing: MilestoneItem?
  @State private var key: String
  @State private var keyEdited: Bool
  @State private var label: String
  @State private var subject: String?
  @State private var kind: StoredEnum<MilestoneKind>

  init(model: StoryModel, editing: MilestoneItem?) {
    self.model = model
    self.editing = editing
    _key = State(initialValue: editing?.record.milestone ?? "")
    _keyEdited = State(initialValue: editing != nil)
    _label = State(initialValue: editing?.record.label ?? "")
    _subject = State(initialValue: editing?.record.subject)
    _kind = State(initialValue: editing?.record.kind ?? .known(.custom))
  }

  var body: some View {
    StoryFormScaffold(
      heading: editing == nil ? LocalizedStringResource("New Milestone", table: "Story") : LocalizedStringResource("Edit Milestone", table: "Story"),
      confirmTitle: editing == nil ? Text("Create", tableName: "Story") : Text("Save", tableName: "Story"),
      canSubmit: StoryKey.isValid(key) && label.storyNonBlank != nil && (editing == nil || hasChanges), hasChanges: hasChanges, submit: submit
    ) {
      StoryField(Text("Label", tableName: "Story")) {
        TextField(text: $label, prompt: Text("Reaches the capital", tableName: "Story")) { Text("Label", tableName: "Story") }.shadowField()
          .onChange(of: label) { if !keyEdited { key = StoryKey.slug(label) } }
      }
      StoryField(Text("Key", tableName: "Story"), hint: Text("A short unique name, without spaces. It cannot change later.", tableName: "Story")) {
        TextField(text: $key) { Text("Key", tableName: "Story") }.shadowField().disabled(editing != nil)
          .onChange(of: key) { if editing == nil && key != StoryKey.slug(label) { keyEdited = true } }
      }
      StoryField(Text("Kind", tableName: "Story")) {
        Picker(selection: $kind) {
          if case .unknown(let raw) = editing?.record.kind { Text(verbatim: raw).tag(StoredEnum<MilestoneKind>.unknown(raw)) }
          ForEach(MilestoneKind.allCases, id: \.self) { $0.title.tag(StoredEnum<MilestoneKind>.known($0)) }
        } label: {
          Text("Kind", tableName: "Story")
        }
        .labelsHidden()
      }
      StoryField(Text("About", tableName: "Story"), hint: Text("The character or thing this milestone is about.", tableName: "Story")) {
        Picker(selection: $subject) {
          Text("Nobody in particular", tableName: "Story").tag(String?.none)
          ForEach(entities, id: \.entity) { Text(verbatim: $0.name).tag(String?.some($0.entity)) }
        } label: {
          Text("About", tableName: "Story")
        }
        .labelsHidden()
      }
    }
  }

  private var entities: [EntityRecord] { model.bible.value?.entities.value?.items ?? [] }

  private var hasChanges: Bool {
    guard let editing else { return !label.isEmpty || !key.isEmpty }
    return label != editing.record.label || subject != editing.record.subject || kind != editing.record.kind
  }

  private func submit() async throws {
    if editing == nil {
      try await model.createMilestone(key: key, label: label, subject: subject, kind: kind.known ?? .custom)
    } else {
      try await model.editMilestone(key: key, label: label, subject: subject, kind: kind == editing?.record.kind ? nil : kind.known)
    }
  }
}
