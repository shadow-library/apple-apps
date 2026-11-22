import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct EntityFormSheet: View {
  let model: StoryBibleModel
  let onDone: (String) -> Void
  @State private var form: EntityForm
  @State private var dismissGuard = ShadowDismissGuard()
  @Environment(\.dismiss) private var dismiss

  init(mode: EntityFormMode, model: StoryBibleModel, onDone: @escaping (String) -> Void) {
    self.model = model
    self.onDone = onDone
    _form = State(initialValue: EntityForm(mode: mode))
  }

  var body: some View {
    @Bindable var form = form
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if let failure = form.failure { ShadowValidationMessage(failure.text) }
        typePicker($form.type)
        textField(Text("Name", tableName: "StoryBible"), $form.name, prompt: Text("Name", tableName: "StoryBible"))
        if form.isCreating { keyField() }
        significancePicker($form.significance)
        textField(Text("Status", tableName: "StoryBible"), $form.status, prompt: Text("e.g. alive, missing, destroyed", tableName: "StoryBible"))
        longField(form.type == .character ? Text("Who they are", tableName: "StoryBible") : Text("About", tableName: "StoryBible"), $form.body)
        if form.showsMotivation { longField(Text("Wants", tableName: "StoryBible"), $form.motivation) }
        longField(Text("Appearance", tableName: "StoryBible"), $form.appearance)
        longField(Text("Notes", tableName: "StoryBible"), $form.notes)
      }
      .disabled(form.isSubmitting)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      heading,
      cancel: ShadowSheetCancel(Text("Cancel", tableName: "StoryBible"), isDisabled: form.isSubmitting, action: requestDismiss),
      confirm: ShadowSheetConfirm(confirmTitle, isDisabled: !form.canSubmit, submitShortcut: true) { Task { await submit() } }
    )
    .shadowSheetStyle(.form)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "StoryBible"), discardTitle: Text("Discard", tableName: "StoryBible"),
      keepEditingTitle: Text("Keep Editing", tableName: "StoryBible"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSubmitting) { dismissGuard.isBusy = form.isSubmitting }
    .onChange(of: form.name) { form.edited() }
    .onChange(of: form.key) { form.edited() }
  }

  private var heading: Text { form.isCreating ? Text("New Entity", tableName: "StoryBible") : Text("Edit Entity", tableName: "StoryBible") }
  private var confirmTitle: Text { form.isCreating ? Text("Create", tableName: "StoryBible") : Text("Save", tableName: "StoryBible") }

  private func typePicker(_ selection: Binding<EntityType>) -> some View {
    Picker(selection: selection) {
      ForEach(EntityType.allCases, id: \.self) { type in Text(type.label).tag(type) }
    } label: {
      Text("Kind", tableName: "StoryBible")
    }
    .disabled(!form.isCreating)
  }

  private func significancePicker(_ selection: Binding<EntitySignificance>) -> some View {
    Picker(selection: selection) {
      ForEach(EntitySignificance.allCases, id: \.self) { significance in Text(significance.label).tag(significance) }
    } label: {
      Text("Importance", tableName: "StoryBible")
    }
    .pickerStyle(.segmented)
  }

  private func textField(_ label: Text, _ text: Binding<String>, prompt: Text) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      TextField(text: text, prompt: prompt) { label }.shadowField()
    }
  }

  private func keyField() -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Key", tableName: "StoryBible").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      TextField(
        text: Binding(get: { form.keyEdited ? form.key : BibleKey.slug(from: form.name) }, set: { form.editKey($0) }), prompt: Text("entry-key", tableName: "StoryBible")
      ) { Text("Key", tableName: "StoryBible") }
      .shadowField()
      .shadowValidation(form.keyIssue.map { Text(verbatim: $0) })
      .autocorrectionDisabled()
      Text("Identifies the entry in plans and facts. It cannot be changed later.", tableName: "StoryBible").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private func longField(_ label: Text, _ text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      ShadowTextEditor(text: text, placeholder: label, minHeight: 80, maxHeight: 220) { _ in Text(verbatim: "") }
    }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  private func submit() async {
    guard let key = await form.submit(using: model) else { return }
    dismiss()
    onDone(key)
  }
}
