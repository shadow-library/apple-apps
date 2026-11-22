import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chapters/AmendDialog.tsx:21-76. The content-rating picker (AmendDialog.tsx:62) has no field in `ChapterAmendment`, so it is left out.
struct AmendSheet: View {
  @State private var model: AmendModel
  @State private var dismissGuard = ShadowDismissGuard()
  @State private var confirming = false
  @Environment(\.dismiss) private var dismiss

  init(context: NovelContext, chapter: Int, final: ChapterContent.Final) {
    _model = State(initialValue: AmendModel(context: context, chapter: chapter, final: final))
  }

  var body: some View {
    @Bindable var model = model
    Group {
      if model.isAmended { amended } else { form($model) }
    }
    .shadowSheetHeader(
      Text("Amend Chapter \(model.chapter)", tableName: "Amend"),
      subtitle: Text("Rewrites finalized canon in place. The chapter stays locked and keeps its number.", tableName: "Amend"),
      cancel: ShadowSheetCancel(model.isAmended ? Text("Done", tableName: "Amend") : Text("Cancel", tableName: "Amend"), isDisabled: model.isSaving, action: requestDismiss),
      confirm: model.isAmended
        ? nil : ShadowSheetConfirm(Text("Amend Chapter \(model.chapter)", tableName: "Amend"), isDisabled: !model.canAmend, submitShortcut: true) { confirming = true }
    )
    .shadowSheetStyle(.full)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your changes?", tableName: "Amend"), discardTitle: Text("Discard", tableName: "Amend"),
      keepEditingTitle: Text("Keep Editing", tableName: "Amend"), onDiscard: { dismiss() }
    )
    .confirmationDialog(Text("Replace the final prose?", tableName: "Amend"), isPresented: $confirming) {
      Button(role: .destructive) {
        Task { await model.amend() }
      } label: {
        Text("Replace Prose", tableName: "Amend")
      }
    } message: {
      Text("Chapter \(model.chapter) is final. This overwrites its text; it stays locked and keeps its number.", tableName: "Amend")
    }
    .onChange(of: model.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = model.hasChanges }
    .onChange(of: model.isSaving) { dismissGuard.isBusy = model.isSaving }
    .alert(Text(verbatim: failure?.headline ?? ""), isPresented: Binding(get: { failure != nil }, set: { if !$0 { model.dismissFailure() } }), presenting: failure) { _ in
      Button {
        model.dismissFailure()
      } label: {
        Text("OK", tableName: "Amend")
      }
    } message: { failure in
      if let detail = failure.detail { Text(verbatim: detail) }
    }
  }

  private var failure: PresentedError? {
    guard case .failed(let error) = model.phase else { return nil }
    return error
  }

  private func form(_ model: Bindable<AmendModel>) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        ShadowCallout(
          Text("Prose only", tableName: "Amend"),
          message: Text(
            "The Story Bible, continuity, and every later chapter are untouched. Anything this chapter already contributed to canon keeps propagating until you re-derive it.",
            tableName: "Amend"), intent: .warning
        ) { EmptyView() }
        field(Text("Prose", tableName: "Amend")) {
          ShadowTextEditor(text: model.body, placeholder: Text("The chapter's text", tableName: "Amend"), minHeight: 240) { _ in Text(verbatim: "") }
        }
        field(Text("Title", tableName: "Amend")) {
          TextField(text: model.title, prompt: Text("Untitled chapter", tableName: "Amend")) { Text("Title", tableName: "Amend") }.shadowField()
        }
        field(Text("Author's note", tableName: "Amend")) {
          TextField(text: model.note, prompt: Text("Leave empty to keep the current note", tableName: "Amend")) { Text("Author's note", tableName: "Amend") }.shadowField()
          Text("Reaches the reader.", tableName: "Amend").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
      .disabled(self.model.isSaving)
    }
  }

  private var amended: some View {
    ShadowContentUnavailable(
      Text("Chapter \(model.chapter) amended", tableName: "Amend"), systemImage: "checkmark.circle",
      message: Text(
        "The amendment replaced prose only. Anything this chapter already contributed to the Story Bible is still there and still propagating; later chapters were not changed.",
        tableName: "Amend")
    ) {
      Button {
        dismiss()
      } label: {
        Text("Done", tableName: "Amend")
      }
    }
  }

  private func field(_ label: Text, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      label.shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      content()
    }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }
}
