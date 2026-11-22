import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowJobs
import SwiftUI

/// apps/novel-forge-web/src/features/chapters/SummarizeDialog.tsx:18-142. An isolated draft's continuation state can be reviewed here but not saved: the core has
/// no write for it, so only the summary is applied (SummarizeDialog.tsx:66-67 applies both).
struct SummarizeSheet: View {
  let autoRun: Bool
  @State private var model: SummarizeModel
  @State private var dismissGuard = ShadowDismissGuard()
  @State private var started = false
  @Environment(\.dismiss) private var dismiss

  init(context: NovelContext, chapter: Int, runtime: JobRuntime?, autoRun: Bool) {
    self.autoRun = autoRun
    _model = State(initialValue: SummarizeModel(context: context, chapter: chapter, summarizer: runtime?.engine.map(SummarizeModel.summarizer)))
  }

  var body: some View {
    @Bindable var model = model
    content($model)
      .shadowSheetHeader(
        Text("Summary of Chapter \(model.chapter)", tableName: "Amend"), subtitle: subtitle,
        cancel: ShadowSheetCancel(Text("Cancel", tableName: "Amend"), isDisabled: model.phase == .saving, action: requestDismiss),
        confirm: ShadowSheetConfirm(Text("Save Summary", tableName: "Amend"), isDisabled: !model.canSave, submitShortcut: true) { Task { await model.save() } }
      )
      .shadowSheetStyle(.full)
      .shadowDismissGuard(
        $dismissGuard, title: Text("Discard your changes?", tableName: "Amend"), discardTitle: Text("Discard", tableName: "Amend"),
        keepEditingTitle: Text("Keep Editing", tableName: "Amend"), onDiscard: { dismiss() }
      )
      .onChange(of: model.hasChanges, initial: true) { dismissGuard.hasUnsavedChanges = model.hasChanges }
      .onChange(of: model.isBusy) { dismissGuard.isBusy = model.isBusy }
      .onChange(of: model.phase) { if model.phase == .saved { dismiss() } }
      .task {
        await model.load()
        guard autoRun, !started else { return }
        started = true
        await model.summarize()
      }
  }

  private var subtitle: Text {
    if model.isUnsavedIsolated { Text("Review the summary, then save it to the draft.", tableName: "Amend") } else { Text("Chapter \(model.chapter)", tableName: "Amend") }
  }

  @ViewBuilder
  private func content(_ model: Bindable<SummarizeModel>) -> some View {
    switch self.model.phase {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 240)
    case .failed(let error):
      ShadowContentUnavailable(Text("Unavailable", tableName: "Amend"), kind: .error, message: error.text) {
        Button {
          Task { await self.model.load() }
        } label: {
          Text("Try Again", tableName: "Amend")
        }
      }
    case .ready, .summarizing, .saving, .saved:
      form(model)
    }
  }

  private func form(_ model: Bindable<SummarizeModel>) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        notices
        if self.model.phase == .summarizing {
          HStack(spacing: Spacing.space2) {
            ProgressView()
            Text("Reading the chapter…", tableName: "Amend").foregroundStyle(ShadowColor.textSecondary)
          }
        } else {
          Button {
            Task { await self.model.summarize() }
          } label: {
            Label(title: { Text("Summarize with AI", tableName: "Amend") }, icon: { Image(systemName: "sparkles") })
          }
          .disabled(!self.model.canSummarize)
        }
        VStack(alignment: .leading, spacing: Spacing.space2) {
          Text("Summary", tableName: "Amend").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
          ShadowTextEditor(text: model.summary, placeholder: Text("Two or three sentences, past tense", tableName: "Amend"), minHeight: 120) { _ in Text(verbatim: "") }
            .disabled(self.model.isBusy)
          Text("Two or three sentences, past tense. This is all the next chapter sees of this one.", tableName: "Amend")
            .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        if let stateText = self.model.stateText, self.model.isUnsavedIsolated { stateField(stateText) }
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private var notices: some View {
    if let failure = model.failure {
      ShadowCallout(Text(verbatim: failure.headline), message: failure.detail.map { Text(verbatim: $0) }, intent: .danger) { EmptyView() }
    }
    switch model.notice {
    case .conflict:
      ShadowCallout(
        Text("This chapter changed while summarizing", tableName: "Amend"),
        message: Text("The summary below may describe text that is gone. Review it before saving.", tableName: "Amend"), intent: .warning
      ) { EmptyView() }
    case .unsaved:
      ShadowCallout(
        Text("Not saved yet", tableName: "Amend"),
        message: Text("This chapter's prose stays private, so its summary waits for your review. Save it to keep it.", tableName: "Amend"),
        intent: .info
      ) { EmptyView() }
    case .savedByModel:
      ShadowCallout(Text("Summary saved", tableName: "Amend"), message: Text("Edit it and save again if you change it.", tableName: "Amend"), intent: .success) { EmptyView() }
    case nil:
      EmptyView()
    }
  }

  private func stateField(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Continuation state", tableName: "Amend").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      Text("What the next chapter builds on. It is shown for review only; this screen cannot save it yet.", tableName: "Amend")
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }
}
