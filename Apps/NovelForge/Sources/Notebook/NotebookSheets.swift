import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension View {
  func notebookSheets(_ model: NotebookModel) -> some View {
    modifier(NotebookSheetsModifier(model: model))
  }
}

private struct NotebookSheetsModifier: ViewModifier {
  @Bindable var model: NotebookModel

  func body(content: Content) -> some View {
    content.sheet(item: $model.presenting) { sheet in
      switch sheet {
      case .add(let kind): NotebookEntrySheet(model: model, mode: .add(kind))
      case .rewrite(let entry): NotebookEntrySheet(model: model, mode: .rewrite(entry))
      case .withdraw(let entry): NotebookWithdrawSheet(model: model, entry: entry)
      }
    }
  }
}

struct NotebookEntrySheet: View {
  let model: NotebookModel
  @State private var form: NotebookEntryForm
  @State private var dismissGuard = ShadowDismissGuard()
  @Environment(\.dismiss) private var dismiss

  init(model: NotebookModel, mode: NotebookFormMode) {
    self.model = model
    _form = State(initialValue: NotebookEntryForm(mode: mode))
  }

  var body: some View {
    @Bindable var form = form
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if let error = form.issues.form { ShadowValidationMessage(error.text) }
        kindPicker($form.kind)
        if !form.isRewrite { topicField($form.topic) }
        textField(Text("Statement", tableName: "Notebook"), text: $form.statement, issue: form.statementIssue, minHeight: 90)
        textField(Text("Why", tableName: "Notebook"), text: $form.why, issue: form.whyIssue, minHeight: 70, optional: true)
        if form.showsWriterLine { textField(Text("For the writer", tableName: "Notebook"), text: $form.writerLine, issue: form.writerLineIssue, minHeight: 60, optional: true) }
      }
      .padding(.bottom, Spacing.space1)
      .disabled(form.isSubmitting)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text(heading), subtitle: subtitle.map { Text($0) },
      cancel: ShadowSheetCancel(Text("Cancel", tableName: "Notebook"), isDisabled: form.isSubmitting, action: requestDismiss),
      confirm: ShadowSheetConfirm(form.isRewrite ? Text("Save", tableName: "Notebook") : Text("Add", tableName: "Notebook"), isDisabled: !form.canSubmit, submitShortcut: true) {
        Task { await submit() }
      }
    )
    .shadowSheetStyle(.form)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Notebook"), discardTitle: Text("Discard", tableName: "Notebook"),
      keepEditingTitle: Text("Keep Editing", tableName: "Notebook"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSubmitting) { dismissGuard.isBusy = form.isSubmitting }
    .onChange(of: form.statement) { form.edited() }
    .onChange(of: form.topic) { form.edited() }
    .onChange(of: form.kind) { form.edited() }
  }

  private func kindPicker(_ selection: Binding<LedgerEntryKind>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label(Text("Kind", tableName: "Notebook"))
      Picker(selection: selection) {
        ForEach(form.kinds, id: \.self) { kind in Text(kind.notebookTitle).tag(kind) }
      } label: {
        Text("Kind", tableName: "Notebook")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  private func topicField(_ text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label(Text("Topic", tableName: "Notebook"))
      TextField(text: text, prompt: Text("e.g. voice.tense", tableName: "Notebook")) { Text("Topic", tableName: "Notebook") }
        .shadowField()
        .shadowValidation(form.topicIssue.map { Text(verbatim: $0) })
        .autocorrectionDisabled()
      Text("Lowercase words joined by dots, dashes or underscores. Entries on one topic replace each other.", tableName: "Notebook")
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private func textField(_ title: Text, text: Binding<String>, issue: String?, minHeight: CGFloat, optional: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        label(title)
        if optional { Text("Optional", tableName: "Notebook").shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary) }
      }
      ShadowTextEditor(text: text, placeholder: Text(verbatim: ""), minHeight: minHeight, maxHeight: 220) { _ in Text(verbatim: "") }
      if let issue { ShadowValidationMessage(Text(verbatim: issue)) }
    }
  }

  private func label(_ text: Text) -> some View {
    text.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
  }

  private var heading: LocalizedStringResource {
    form.isRewrite ? LocalizedStringResource("Rewrite Entry", table: "Notebook") : LocalizedStringResource("Add Entry", table: "Notebook")
  }

  private var subtitle: LocalizedStringResource? {
    form.isRewrite ? LocalizedStringResource("The earlier wording is kept in the entry's history.", table: "Notebook") : nil
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  private func submit() async {
    guard await form.submit(using: model) != nil else { return }
    dismiss()
  }
}

struct NotebookWithdrawSheet: View {
  let model: NotebookModel
  @State private var form: NotebookWithdrawForm
  @State private var dismissGuard = ShadowDismissGuard()
  @Environment(\.dismiss) private var dismiss

  init(model: NotebookModel, entry: NotebookEntry) {
    self.model = model
    _form = State(initialValue: NotebookWithdrawForm(entry: entry))
  }

  var body: some View {
    @Bindable var form = form
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if let error = form.issues.form { ShadowValidationMessage(error.text) }
        Text(verbatim: form.entry.record.statement).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary).lineLimit(4)
        VStack(alignment: .leading, spacing: Spacing.space2) {
          Text("Reason", tableName: "Notebook").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
          ShadowTextEditor(text: $form.reason, placeholder: Text("Why is this no longer true?", tableName: "Notebook"), minHeight: 90, maxHeight: 220) { _ in Text(verbatim: "") }
          if let issue = form.reasonIssue { ShadowValidationMessage(Text(verbatim: issue)) }
        }
      }
      .disabled(form.isSubmitting)
    }
    .scrollBounceBehavior(.basedOnSize)
    .shadowSheetHeader(
      Text("Withdraw Entry", tableName: "Notebook"), subtitle: Text("It leaves the active Notebook and stays in its history.", tableName: "Notebook"),
      cancel: ShadowSheetCancel(Text("Cancel", tableName: "Notebook"), isDisabled: form.isSubmitting, action: requestDismiss),
      confirm: ShadowSheetConfirm(Text("Withdraw", tableName: "Notebook"), isDisabled: !form.canSubmit, submitShortcut: true) { Task { await submit() } }
    )
    .shadowSheetStyle(.form)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Notebook"), discardTitle: Text("Discard", tableName: "Notebook"),
      keepEditingTitle: Text("Keep Editing", tableName: "Notebook"), onDiscard: { dismiss() }
    )
    .onChange(of: form.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = form.hasChanges }
    .onChange(of: form.isSubmitting) { dismissGuard.isBusy = form.isSubmitting }
    .onChange(of: form.reason) { form.edited() }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  private func submit() async {
    guard await form.submit(using: model) else { return }
    dismiss()
  }
}
