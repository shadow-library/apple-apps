import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct PageFormSheet: View {
  let model: StoryBibleModel
  let derivedTitle: String?
  let onDone: (PageAddress) -> Void
  @State private var form: PageForm
  @State private var dismissGuard = ShadowDismissGuard()
  @Environment(\.dismiss) private var dismiss

  init(mode: PageFormMode, derivedTitle: String? = nil, model: StoryBibleModel, onDone: @escaping (PageAddress) -> Void) {
    self.model = model
    self.derivedTitle = derivedTitle
    self.onDone = onDone
    _form = State(initialValue: PageForm(mode: mode))
  }

  var body: some View {
    @Bindable var form = form
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if let failure = form.failure { ShadowValidationMessage(failure.text) }
        if form.isCreating { sectionPicker($form.section) }
        titleField($form.title)
        if form.isCreating { slugField() }
        bodyField($form.body)
      }
      .disabled(form.isSubmitting)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text(form.isCreating ? "New Page" : "Edit Page", tableName: "StoryBible"),
      cancel: ShadowSheetCancel(Text("Cancel", tableName: "StoryBible"), isDisabled: form.isSubmitting, action: requestDismiss),
      confirm: ShadowSheetConfirm(Text(form.isCreating ? "Create" : "Save", tableName: "StoryBible"), isDisabled: !form.canSubmit, submitShortcut: true) {
        Task { await submit() }
      }
    )
    .shadowSheetStyle(.form)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "StoryBible"), discardTitle: Text("Discard", tableName: "StoryBible"),
      keepEditingTitle: Text("Keep Editing", tableName: "StoryBible"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSubmitting) { dismissGuard.isBusy = form.isSubmitting }
    .onChange(of: form.title) { form.edited() }
    .onChange(of: form.body) { form.edited() }
  }

  private func sectionPicker(_ selection: Binding<BiblePageSection>) -> some View {
    Picker(selection: selection) {
      ForEach(BiblePageSection.allCases, id: \.self) { section in Text(section.label).tag(section) }
    } label: {
      Text("Section", tableName: "StoryBible")
    }
  }

  private func titleField(_ text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Title", tableName: "StoryBible").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      TextField(text: text, prompt: titlePrompt) { Text("Title", tableName: "StoryBible") }.shadowField()
      if !form.isCreating {
        Text("Leave it blank to use the page's first heading.", tableName: "StoryBible").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private var titlePrompt: Text {
    guard let derivedTitle else { return Text("Page title", tableName: "StoryBible") }
    return Text(verbatim: derivedTitle)
  }

  private func slugField() -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Address", tableName: "StoryBible").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      TextField(
        text: Binding(get: { form.slugEdited ? form.slug : form.suggestedSlug }, set: { form.editSlug($0) }), prompt: Text("page-address", tableName: "StoryBible")
      ) { Text("Address", tableName: "StoryBible") }
      .shadowField()
      .shadowValidation(form.slugIssue.map { Text(verbatim: $0) })
      .autocorrectionDisabled()
    }
  }

  private func bodyField(_ text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Text", tableName: "StoryBible").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      ShadowTextEditor(text: text, placeholder: Text("Write in Markdown.", tableName: "StoryBible"), minHeight: 240, maxHeight: 420) { _ in Text(verbatim: "") }
    }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  private func submit() async {
    guard let address = await form.submit(using: model) else { return }
    dismiss()
    onDone(address)
  }
}
