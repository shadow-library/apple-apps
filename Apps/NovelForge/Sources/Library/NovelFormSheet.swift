import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct NovelFormSheet: View {
  let library: LibraryModel
  @State private var form: NovelForm
  @State private var dismissGuard = ShadowDismissGuard()
  @Environment(\.dismiss) private var dismiss

  init(mode: NovelFormMode, library: LibraryModel) {
    self.library = library
    _form = State(initialValue: NovelForm(mode: mode))
  }

  var body: some View {
    @Bindable var form = form
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if let error = form.issues.form { ShadowValidationMessage(error.text) }
        titleField($form.title)
        if form.showsNotes { notesField($form.notes) }
      }
      .padding(.bottom, Spacing.space1)
      .disabled(form.isSubmitting)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text(heading), subtitle: subtitle.map { Text($0) }, cancel: ShadowSheetCancel(Text("Cancel", tableName: "Library"), isDisabled: form.isSubmitting, action: requestDismiss),
      confirm: ShadowSheetConfirm(confirmTitle, isDisabled: !form.canSubmit, submitShortcut: true) { Task { await submit() } }
    )
    .shadowSheetStyle(.form)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Library"), discardTitle: Text("Discard", tableName: "Library"),
      keepEditingTitle: Text("Keep Editing", tableName: "Library"), onDiscard: { dismiss() }
    )
    .task { await form.loadNotes(using: library) }
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSubmitting) { dismissGuard.isBusy = form.isSubmitting }
    .onChange(of: form.title) { form.edited() }
    .onChange(of: form.notes) { form.edited() }
  }

  private func titleField(_ text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      fieldLabel(titleLabel)
      TextField(text: text, prompt: titlePlaceholder) { titleLabel }
        .shadowField()
        .shadowValidation(form.titleIssue.map { Text(verbatim: $0) })
        .onSubmit { Task { await submit() } }
      if let hint = titleHint {
        hint.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private func notesField(_ text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        fieldLabel(Text("Your notes", tableName: "Library"))
        Text("Optional", tableName: "Library").shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary)
        Spacer(minLength: Spacing.space3)
        notesCounter.shadowFont(.footnote).monospacedDigit()
      }
      ShadowTextEditor(
        text: text,
        placeholder: Text(
          "Characters, the world, the first scene, the ending, books you love. Anything. Nothing you write here is changed; it stays as your source.", tableName: "Library"),
        minHeight: 120, maxHeight: 220
      ) { _ in Text(verbatim: "") }
      .disabled(!form.notesEditable)
      notesFooter
    }
  }

  @ViewBuilder
  private var notesFooter: some View {
    if case .failed(let error) = form.notesLoad {
      ShadowValidationMessage(error.text)
    } else if let issue = form.notesIssue {
      ShadowValidationMessage(Text(verbatim: issue))
    }
  }

  @ViewBuilder
  private var notesCounter: some View {
    let words = form.notesWords
    if words == 0 {
      Text("Up to \(LibraryLimits.notesWords) words", tableName: "Library").foregroundStyle(ShadowColor.textSecondary)
    } else {
      let isOver = form.notesWordsOver > 0
      HStack(spacing: Spacing.space1) {
        Text("\(words) words", tableName: "Library")
        Text(verbatim: "·")
        if isOver {
          Text("\(form.notesWordsOver) over", tableName: "Library")
        } else {
          Text("\(form.notesWordsLeft) left", tableName: "Library")
        }
      }
      .foregroundStyle(isOver ? ShadowColor.destructiveLabel : ShadowColor.textSecondary)
    }
  }

  private func fieldLabel(_ text: Text) -> some View {
    text.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  private func submit() async {
    guard await form.submit(using: library) != nil else { return }
    dismiss()
  }

  private var heading: LocalizedStringResource {
    switch form.mode {
    case .create: LocalizedStringResource("Start a New Novel", table: "Library")
    case .edit: LocalizedStringResource("Edit Novel", table: "Library")
    case .clone: LocalizedStringResource("Clone Novel", table: "Library")
    }
  }

  private var subtitle: LocalizedStringResource? {
    switch form.mode {
    case .create: LocalizedStringResource("Give it a working title. Paste any notes you already have.", table: "Library")
    case .edit: nil
    case .clone: LocalizedStringResource("Creates a fresh copy you can experiment with.", table: "Library")
    }
  }

  private var confirmTitle: Text {
    switch form.mode {
    case .create: Text("Create", tableName: "Library")
    case .edit: Text("Save", tableName: "Library")
    case .clone: Text("Clone", tableName: "Library")
    }
  }

  private var titleLabel: Text {
    switch form.mode {
    case .create, .edit: Text("Working name", tableName: "Library")
    case .clone: Text("New novel name", tableName: "Library")
    }
  }

  private var titlePlaceholder: Text {
    switch form.mode {
    case .create: Text("Untitled novel", tableName: "Library")
    case .edit(_, let title): Text(verbatim: title)
    case .clone(_, let title): Text("e.g. \(title) (copy)", tableName: "Library")
    }
  }

  private var titleHint: Text? {
    switch form.mode {
    case .create: Text("Optional. You can rename it any time.", tableName: "Library")
    case .edit: Text("Leave it blank to show the novel's name.", tableName: "Library")
    case .clone: nil
    }
  }
}
