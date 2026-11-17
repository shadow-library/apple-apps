import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension StoryPromise {
  var kindTitle: Text {
    switch self {
    case .thread: Text("Thread", tableName: "Story")
    case .mystery: Text("Mystery", tableName: "Story")
    }
  }

  var settledTitle: Text {
    switch self {
    case .thread: Text("Closed", tableName: "Story")
    case .mystery: Text("Resolved", tableName: "Story")
    }
  }

  var pill: ShadowBadge {
    switch standing {
    case .open: isDormant ? ShadowBadge(Text("Dormant", tableName: "Story"), intent: .neutral) : ShadowBadge(Text("Open", tableName: "Story"), intent: .accent)
    case .settled: ShadowBadge(settledTitle, intent: .success)
    case .dropped: ShadowBadge(Text("Dropped", tableName: "Story"), intent: .neutral)
    case .unrecognised: ShadowBadge(Text("Unknown", tableName: "Story"), intent: .warning)
    }
  }

  var chapterNote: Text? {
    switch chapterMark {
    case .settled(let chapter): Text("Settled in chapter \(chapter)", tableName: "Story")
    case .opened(let chapter): Text("Opened in chapter \(chapter)", tableName: "Story")
    case nil: nil
    }
  }
}

struct PromisesTab: View {
  let model: StoryModel
  let structure: StoryStructure

  var body: some View {
    switch structure.promises {
    case .unavailable(let faults):
      StoryUnavailable(faults: faults)
    case .available(let section):
      if section.items.isEmpty && model.restorable.isEmpty {
        ShadowContentUnavailable(
          Text("No promises yet", tableName: "Story"), systemImage: "link",
          message: Text("Threads and mysteries are promises to the reader that the story must pay off.", tableName: "Story")
        ) {
          Button {
            model.present(.newPromise)
          } label: {
            Text("New Promise", tableName: "Story")
          }
        }
        .fillingSurface()
      } else {
        list(section)
      }
    }
  }

  private func list(_ section: StructureSection<StoryPromise>) -> some View {
    List {
      if section.unreadable > 0 { ShadowCallout(Text("\(section.unreadable) promises cannot be read by this version", tableName: "Story"), intent: .warning) }
      Section {
        ForEach(section.items, id: \.ref) { item in
          NavigationLink(value: StoryRoute.promise(item.ref)) { PromiseRow(item: item) }
            .shadowListRowChrome()
            .contextMenu { PromiseActions(model: model, item: item) }
        }
      }
      RemovedItemsSection(model: model, items: model.restorable.filter { if case .promise = $0 { true } else { false } })
    }
    .shadowListStyle()
    .shadowScreen(.root)
  }
}

struct PromiseRow: View {
  let item: StoryPromise

  var body: some View {
    ShadowListRow(
      title: Text(verbatim: item.label), subtitle: item.chapterNote, caption: item.kindTitle,
      leading: {
        Image(systemName: item.ref.kindName == "thread" ? "point.topleft.down.to.point.bottomright.curvepath" : "questionmark.circle").foregroundStyle(ShadowColor.textSecondary)
      },
      trailing: { item.pill })
  }
}

struct PromiseActions: View {
  let model: StoryModel
  let item: StoryPromise

  var body: some View {
    switch item.standing {
    case .open:
      Button {
        Task { await model.settle(item.ref, .payOff) }
      } label: {
        Label(title: { Text("Settle", tableName: "Story") }, icon: { Image(systemName: "checkmark.circle") })
      }
      Button {
        model.confirmingDrop = item.ref
      } label: {
        Label(title: { Text("Drop…", tableName: "Story") }, icon: { Image(systemName: "xmark.circle") })
      }
    case .settled, .dropped:
      Button {
        Task { await model.settle(item.ref, .reopen) }
      } label: {
        Label(title: { Text("Reopen", tableName: "Story") }, icon: { Image(systemName: "arrow.uturn.backward") })
      }
    case .unrecognised:
      EmptyView()
    }
    Button {
      model.present(.editPromise(item.ref))
    } label: {
      Label(title: { Text("Edit…", tableName: "Story") }, icon: { Image(systemName: "pencil") })
    }
    Divider()
    Button(role: .destructive) {
      Task { await model.removePromise(item) }
    } label: {
      Label(title: { Text("Remove", tableName: "Story") }, icon: { Image(systemName: "trash") })
    }
  }
}

struct PromiseDetailView: View {
  let model: StoryModel
  let promise: PromiseRef

  var body: some View {
    StoryLoaded(model: model) { structure in
      switch structure.promises {
      case .unavailable(let faults): StoryUnavailable(faults: faults)
      case .available:
        if let item = structure.promise(promise) {
          details(item)
        } else {
          StoryNotFound(title: Text("Promise not found", tableName: "Story"))
        }
      }
    }
    .navigationTitle(Text(verbatim: model.structure.value?.promise(promise)?.label ?? promise.key))
    .storyPresentations(model)
  }

  private func details(_ item: StoryPromise) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        HStack(spacing: Spacing.space3) {
          item.kindTitle.shadowFont(.headline).foregroundStyle(ShadowColor.textSecondary)
          item.pill
        }
        Text(verbatim: item.label).shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
        Text(verbatim: item.ref.key).shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary).textSelection(.enabled)
        if let note = item.chapterNote { note.shadowFont(.body).foregroundStyle(ShadowColor.textSecondary) }
        HStack(spacing: Spacing.space3) {
          switch item.standing {
          case .open:
            Button {
              Task { await model.settle(item.ref, .payOff) }
            } label: {
              Text("Settle", tableName: "Story")
            }
            Button {
              model.confirmingDrop = item.ref
            } label: {
              Text("Drop…", tableName: "Story")
            }
          case .settled, .dropped:
            Button {
              Task { await model.settle(item.ref, .reopen) }
            } label: {
              Text("Reopen", tableName: "Story")
            }
          case .unrecognised:
            EmptyView()
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
          PromiseActions(model: model, item: item)
        } label: {
          Label(title: { Text("Actions", tableName: "Story") }, icon: { Image(systemName: "ellipsis.circle") })
        }
        .shadowBarItem()
      }
    }
  }
}

struct PromiseFormSheet: View {
  enum Kind: Hashable {
    case thread
    case mystery
  }

  let model: StoryModel
  let editing: StoryPromise?
  @State private var kind: Kind
  @State private var key: String
  @State private var keyEdited: Bool
  @State private var label: String

  init(model: StoryModel, editing: StoryPromise?) {
    self.model = model
    self.editing = editing
    _kind = State(initialValue: editing?.ref.kindName == "mystery" ? .mystery : .thread)
    _key = State(initialValue: editing?.ref.key ?? "")
    _keyEdited = State(initialValue: editing != nil)
    _label = State(initialValue: editing?.label ?? "")
  }

  var body: some View {
    StoryFormScaffold(
      heading: editing == nil ? LocalizedStringResource("New Promise", table: "Story") : LocalizedStringResource("Edit Promise", table: "Story"),
      confirmTitle: editing == nil ? Text("Create", tableName: "Story") : Text("Save", tableName: "Story"),
      canSubmit: StoryKey.isValid(key) && label.storyNonBlank != nil && (editing == nil || label != editing?.label), hasChanges: hasChanges, submit: submit
    ) {
      StoryField(Text("Kind", tableName: "Story")) {
        Picker(selection: $kind) {
          Text("Thread", tableName: "Story").tag(Kind.thread)
          Text("Mystery", tableName: "Story").tag(Kind.mystery)
        } label: {
          Text("Kind", tableName: "Story")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(editing != nil)
      }
      StoryField(kind == .thread ? Text("Summary", tableName: "Story") : Text("Question", tableName: "Story")) {
        TextField(text: $label) { Text("Label", tableName: "Story") }.shadowField()
          .onChange(of: label) { if !keyEdited { key = StoryKey.slug(label) } }
      }
      StoryField(Text("Key", tableName: "Story"), hint: Text("A short unique name, without spaces. It cannot change later.", tableName: "Story")) {
        TextField(text: $key) { Text("Key", tableName: "Story") }.shadowField().disabled(editing != nil)
          .onChange(of: key) { if editing == nil && key != StoryKey.slug(label) { keyEdited = true } }
      }
    }
  }

  private var hasChanges: Bool {
    guard let editing else { return !label.isEmpty || !key.isEmpty }
    return label != editing.label
  }

  private var reference: PromiseRef { kind == .thread ? .thread(key) : .mystery(key) }

  private func submit() async throws {
    if editing == nil {
      try await model.createPromise(reference, label: label)
    } else {
      try await model.editPromise(reference, label: label)
    }
  }
}
