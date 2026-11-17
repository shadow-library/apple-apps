import Foundation
import NovelForgeCore
import ShadowCore
import ShadowDesignSystem
import SwiftUI

extension StoryModel {
  func describe(_ term: UnlockTerm) -> String {
    switch term {
    case .milestone(let key): String(localized: "milestone “\(structure.value?.milestone(key)?.record.label ?? key)”", table: "Story")
    case .volume(let key): String(localized: "volume “\(structure.value?.volume(key)?.displayName ?? key)”", table: "Story")
    case .chapter(let number): String(localized: "chapter \(number)", table: "Story")
    case .ending: String(localized: "the ending", table: "Story")
    }
  }

  func timing(of secret: SecretRecord) -> Text? {
    guard let terms = UnlockTerm.parse(secret.unlock) else { return Text("Unlocks on a custom condition", tableName: "Story") }
    let condition = terms.map(describe).formatted(.list(type: .and))
    switch (secret.revealChapter, terms.isEmpty) {
    case (let chapter?, true): return Text("Revealed in chapter \(chapter)", tableName: "Story")
    case (let chapter?, false): return Text("Reveal chapter \(chapter); unlocks after \(condition)", tableName: "Story")
    case (nil, false): return Text("Unlocks after \(condition)", tableName: "Story")
    case (nil, true): return nil
    }
  }
}

struct SecretsTab: View {
  let model: StoryModel
  let structure: StoryStructure

  var body: some View {
    switch structure.secrets {
    case .unavailable(let faults):
      StoryUnavailable(faults: faults)
    case .available(let section):
      if section.items.isEmpty && model.restorable.isEmpty {
        ShadowContentUnavailable(
          Text("No secrets yet", tableName: "Story"), systemImage: "lock",
          message: Text("Secrets are facts the reader must not learn before their reveal chapter or unlock condition.", tableName: "Story")
        ) {
          Button {
            model.present(.newSecret)
          } label: {
            Text("New Secret", tableName: "Story")
          }
        }
        .fillingSurface()
      } else {
        list(section)
      }
    }
  }

  private func list(_ section: StructureSection<SecretRecord>) -> some View {
    List {
      if let violated = violatingChapters, !violated.isEmpty {
        ShadowCallout(
          Text("\(violated.count) chapter plans break the reveal rule", tableName: "Story"),
          message: Text(
            "A secret is revealed too early in: \(violated.map { String(localized: "chapter \($0)", table: "Story") }.formatted(.list(type: .and)))", tableName: "Story"),
          intent: .warning, systemImage: "exclamationmark.triangle")
      }
      if section.unreadable > 0 { ShadowCallout(Text("\(section.unreadable) secrets cannot be read by this version", tableName: "Story"), intent: .warning) }
      Section {
        ForEach(section.items, id: \.secret) { secret in
          NavigationLink(value: StoryRoute.secret(secret.secret)) { SecretRow(model: model, secret: secret) }
            .shadowListRowChrome()
            .contextMenu { SecretActions(model: model, secret: secret) }
        }
      }
      RemovedItemsSection(model: model, items: model.restorable.filter { if case .secret = $0 { true } else { false } })
    }
    .shadowListStyle()
    .shadowScreen(.root)
  }

  private var violatingChapters: [Int]? {
    guard let reveals = model.chapters.value?.reveals.value else { return nil }
    return reveals.filter { $0.value == .violated }.keys.sorted()
  }
}

struct SecretRow: View {
  let model: StoryModel
  let secret: SecretRecord

  var body: some View {
    ShadowListRow(
      title: Text(verbatim: secret.text), subtitle: model.timing(of: secret) ?? Text("No reveal timing set", tableName: "Story"), caption: Text(verbatim: secret.secret),
      leading: { Image(systemName: "lock").foregroundStyle(ShadowColor.textSecondary) },
      trailing: { EmptyView() })
  }
}

struct SecretActions: View {
  let model: StoryModel
  let secret: SecretRecord

  var body: some View {
    Button {
      model.present(.reveal(secret: secret.secret))
    } label: {
      Label(title: { Text("Reveal to a Character…", tableName: "Story") }, icon: { Image(systemName: "eye") })
    }
    Button {
      model.present(.editSecret(secret.secret))
    } label: {
      Label(title: { Text("Edit…", tableName: "Story") }, icon: { Image(systemName: "pencil") })
    }
    Divider()
    Button(role: .destructive) {
      Task { await model.removeSecret(secret) }
    } label: {
      Label(title: { Text("Remove", tableName: "Story") }, icon: { Image(systemName: "trash") })
    }
  }
}

struct SecretDetailView: View {
  let model: StoryModel
  let key: String

  var body: some View {
    StoryLoaded(model: model) { structure in
      switch structure.secrets {
      case .unavailable(let faults): StoryUnavailable(faults: faults)
      case .available:
        if let secret = structure.secret(key) {
          details(secret)
        } else {
          StoryNotFound(title: Text("Secret not found", tableName: "Story"))
        }
      }
    }
    .navigationTitle(Text(verbatim: model.structure.value?.secret(key)?.secret ?? key))
    .storyPresentations(model)
  }

  private func details(_ secret: SecretRecord) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Text(verbatim: secret.text).shadowFont(.title).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
        Text(verbatim: secret.secret).shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary).textSelection(.enabled)
        (model.timing(of: secret) ?? Text("No reveal timing set", tableName: "Story")).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
        note(Text("Writer's note", tableName: "Story"), secret.writerNote)
        note(Text("Constraint", tableName: "Story"), secret.constraintNote)
        knowers(of: secret)
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.pushed)
    .toolbar {
      ToolbarItemGroup {
        Menu {
          SecretActions(model: model, secret: secret)
        } label: {
          Label(title: { Text("Actions", tableName: "Story") }, icon: { Image(systemName: "ellipsis.circle") })
        }
        .shadowBarItem()
      }
    }
  }

  @ViewBuilder
  private func note(_ title: Text, _ text: String?) -> some View {
    if let text = text?.storyNonBlank {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        title.shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        Text(verbatim: text).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
      }
    }
  }

  private func knowers(of secret: SecretRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack {
        Text("Who knows this", tableName: "Story").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        Spacer()
        Button {
          model.present(.reveal(secret: secret.secret))
        } label: {
          Text("Reveal to a Character…", tableName: "Story")
        }
      }
      switch model.ledger {
      case .loading: ProgressView()
      case .failed(let error): ShadowValidationMessage(error.text)
      case .loaded(let ledger): entries(ledger.knowers(of: secret.secret), secret: secret.secret)
      }
    }
  }

  @ViewBuilder
  private func entries(_ derived: Derived<[CharacterKnowledgeEntry]>, secret: String) -> some View {
    switch derived {
    case .unavailable:
      ShadowCallout(Text("Unavailable", tableName: "Story"), message: Text("Who knows this is not up to date on this device yet.", tableName: "Story"), intent: .warning)
    case .available(let entries) where entries.isEmpty:
      Text("No character knows this yet.", tableName: "Story").shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
    case .available(let entries):
      ForEach(entries, id: \.entity) { entry in
        HStack(spacing: Spacing.space3) {
          VStack(alignment: .leading, spacing: Spacing.space05) {
            Text(verbatim: model.entityName(entry.entity)).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
            Text("From chapter \(entry.chapter)", tableName: "Story").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
          Spacer()
          if entry.status == .provisional { StatusPill(title: Text("Provisional", tableName: "Story"), tone: .warning) }
          StatusPill(title: entry.source == .manual ? Text("Revealed by you", tableName: "Story") : Text("From plans", tableName: "Story"), tone: .neutral)
          if entry.source == .manual {
            Button(role: .destructive) {
              Task { await model.retract(secret: secret, from: entry.entity) }
            } label: {
              Text("Retract", tableName: "Story")
            }
          }
        }
      }
    }
  }
}

struct RevealSheet: View {
  let model: StoryModel
  let secret: String
  @State private var entity: String?
  @State private var chapter: Int
  @State private var note = ""

  init(model: StoryModel, secret: String) {
    self.model = model
    self.secret = secret
    _chapter = State(initialValue: model.chapters.value?.next.value ?? 1)
  }

  var body: some View {
    StoryFormScaffold(
      heading: LocalizedStringResource("Reveal to a Character", table: "Story"), confirmTitle: Text("Reveal", tableName: "Story"), canSubmit: entity != nil,
      hasChanges: entity != nil || !note.isEmpty,
      submit: submit
    ) {
      StoryField(Text("Character", tableName: "Story")) {
        Picker(selection: $entity) {
          Text("Choose…", tableName: "Story").tag(String?.none)
          ForEach(model.characters(), id: \.entity) { Text(verbatim: $0.name).tag(String?.some($0.entity)) }
        } label: {
          Text("Character", tableName: "Story")
        }
        .labelsHidden()
      }
      StoryField(Text("Known from", tableName: "Story")) {
        Stepper(value: $chapter, in: 1...100_000) { Text("Chapter \(chapter)", tableName: "Story").monospacedDigit() }
      }
      StoryField(Text("Note", tableName: "Story")) {
        TextField(text: $note, prompt: Text("Optional", tableName: "Story")) { Text("Note", tableName: "Story") }.shadowField()
      }
    }
  }

  private func submit() async throws {
    guard let entity else { return }
    try await model.reveal(secret: secret, to: entity, chapter: chapter, note: note)
  }
}

struct SecretFormSheet: View {
  let model: StoryModel
  let editing: SecretRecord?
  private let initialTerms: [UnlockTerm]?
  @State private var key: String
  @State private var keyEdited: Bool
  @State private var text: String
  @State private var writerNote: String
  @State private var constraintNote: String
  @State private var fixedChapter: Bool
  @State private var chapter: Int
  @State private var termChapter: Int
  @State private var terms: [UnlockTerm]

  init(model: StoryModel, editing: SecretRecord?) {
    self.model = model
    self.editing = editing
    let parsed = UnlockTerm.parse(editing?.unlock)
    initialTerms = parsed
    _key = State(initialValue: editing?.secret ?? "")
    _keyEdited = State(initialValue: editing != nil)
    _text = State(initialValue: editing?.text ?? "")
    _writerNote = State(initialValue: editing?.writerNote ?? "")
    _constraintNote = State(initialValue: editing?.constraintNote ?? "")
    _fixedChapter = State(initialValue: editing?.revealChapter != nil)
    _chapter = State(initialValue: editing?.revealChapter ?? model.chapters.value?.next.value ?? 1)
    _termChapter = State(initialValue: model.chapters.value?.next.value ?? 1)
    _terms = State(initialValue: parsed ?? [])
  }

  var body: some View {
    StoryFormScaffold(
      heading: editing == nil ? LocalizedStringResource("New Secret", table: "Story") : LocalizedStringResource("Edit Secret", table: "Story"),
      confirmTitle: editing == nil ? Text("Create", tableName: "Story") : Text("Save", tableName: "Story"), canSubmit: canSubmit, hasChanges: hasChanges, submit: submit
    ) {
      StoryField(Text("Secret", tableName: "Story")) {
        ShadowTextEditor(text: $text, placeholder: Text("What the reader must not learn yet", tableName: "Story"), minHeight: 72, maxHeight: 200) { _ in Text(verbatim: "") }
          .onChange(of: text) { if !keyEdited { key = StoryKey.slug(String(text.prefix(40))) } }
      }
      StoryField(Text("Key", tableName: "Story"), hint: Text("A short unique name, without spaces. It cannot change later.", tableName: "Story")) {
        TextField(text: $key) { Text("Key", tableName: "Story") }.shadowField().disabled(editing != nil)
          .onChange(of: key) { if editing == nil && key != StoryKey.slug(String(text.prefix(40))) { keyEdited = true } }
        if keyTaken { ShadowValidationMessage(Text("A secret with this key already exists.", tableName: "Story")) }
      }
      timing
      StoryField(Text("Writer's note", tableName: "Story")) {
        TextField(text: $writerNote, prompt: Text("Optional", tableName: "Story")) { Text("Writer's note", tableName: "Story") }.shadowField()
      }
      StoryField(Text("Constraint", tableName: "Story"), hint: Text("A rule for how the secret may be hinted at.", tableName: "Story")) {
        TextField(text: $constraintNote, prompt: Text("Optional", tableName: "Story")) { Text("Constraint", tableName: "Story") }.shadowField()
      }
    }
  }

  private var timing: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Toggle(isOn: $fixedChapter) { Text("Reveal in a fixed chapter", tableName: "Story") }
      if fixedChapter {
        Stepper(value: $chapter, in: 1...100_000) { Text("Chapter \(chapter)", tableName: "Story").monospacedDigit() }
      }
      if initialTerms == nil {
        Text("This secret has an unlock condition this screen cannot edit. It is kept as it is.", tableName: "Story").shadowFont(.footnote).foregroundStyle(
          ShadowColor.textSecondary)
      } else {
        unlockTerms
      }
    }
  }

  private var unlockTerms: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Unlocks after all of", tableName: "Story").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      ForEach(terms, id: \.self) { term in
        HStack {
          Text(verbatim: model.describe(term)).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
          Spacer()
          Button {
            terms.removeAll { $0 == term }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text("Remove term", tableName: "Story"))
        }
      }
      Menu {
        Menu {
          ForEach(model.structure.value?.milestones.value?.items ?? [], id: \.record.milestone) { item in
            Button(item.record.label) { add(.milestone(item.record.milestone)) }
          }
        } label: {
          Text("Milestone", tableName: "Story")
        }
        Menu {
          ForEach(model.structure.value?.volumes.value?.items ?? [], id: \.record.volume) { item in
            Button(item.displayName) { add(.volume(item.record.volume)) }
          }
        } label: {
          Text("Volume", tableName: "Story")
        }
        Button {
          add(.ending)
        } label: {
          Text("The ending", tableName: "Story")
        }
      } label: {
        Text("Add Condition", tableName: "Story")
      }
      HStack {
        Stepper(value: $termChapter, in: 1...100_000) { Text("Chapter \(termChapter)", tableName: "Story").monospacedDigit() }
        Button {
          add(.chapter(termChapter))
        } label: {
          Text("Add Chapter Condition", tableName: "Story")
        }
      }
    }
  }

  private func add(_ term: UnlockTerm) {
    guard !terms.contains(term) else { return }
    terms.append(term)
  }

  private var keyTaken: Bool { editing == nil && model.structure.value?.secret(key) != nil }

  private var canSubmit: Bool {
    StoryKey.isValid(key) && !keyTaken && text.storyNonBlank != nil && (editing == nil || hasChanges)
  }

  private var hasChanges: Bool {
    guard let editing else { return !text.isEmpty || !key.isEmpty }
    return text != editing.text || (writerNote.storyNonBlank != editing.writerNote?.storyNonBlank) || (constraintNote.storyNonBlank != editing.constraintNote?.storyNonBlank)
      || revealChapter != editing.revealChapter || terms != initialTerms
  }

  private var revealChapter: Int? { fixedChapter ? chapter : nil }

  private func submit() async throws {
    let change: UnlockChange = initialTerms == nil || terms == initialTerms ? .keep : .replace(terms)
    try await model.saveSecret(
      key: key, text: text.trimmingCharacters(in: .whitespacesAndNewlines), writerNote: writerNote, constraintNote: constraintNote, revealChapter: revealChapter, unlock: change)
  }
}
