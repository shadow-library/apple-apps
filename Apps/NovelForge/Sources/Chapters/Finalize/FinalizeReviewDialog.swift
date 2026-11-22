import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// apps/novel-forge-web/src/features/chapter-workspace/FinalizeReviewDialog.tsx:60-507 without the bridge and the undo, which phase 7 has not ported: the
/// approved chapter's Story Bible updates by category, the author's answers, what else blocks finalize, and Finalize.
struct FinalizeReviewDialog: View {
  let context: NovelContext
  let chapter: Int
  @Environment(JobRuntimes.self) private var runtimes
  @Environment(\.dismiss) private var dismiss
  @State private var model: FinalizeModel
  @State private var screen = ReadObserver<FinalizeReviewScreen>()
  @State private var readiness = ReadObserver<FinalizeReadiness>()
  @State private var generation = 0
  @State private var routineOpen = false
  @State private var checkedOpen = false
  @State private var stuck = false
  @State private var failure: PresentedError?
  @State private var dismissGuard = ShadowDismissGuard()

  init(context: NovelContext, chapter: Int) {
    self.context = context
    self.chapter = chapter
    _model = State(initialValue: FinalizeModel(store: context.store, novel: context.novel, chapter: chapter))
  }

  var body: some View {
    let presentation = screen.state.value.map { FinalizePresentation(screen: $0, readiness: readiness.state.value) }
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        content(presentation)
      }
      .padding(Spacing.space6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .shadowSheetHeader(
      title(presentation), subtitle: subtitle(presentation),
      cancel: ShadowSheetCancel(Text("Back to the Chapter", tableName: "Finalize"), isDisabled: model.finalizing) { requestClose() },
      confirm: confirm(presentation)
    )
    .shadowSheetStyle(.full)
    .shadowDismissGuard(
      $dismissGuard, title: Text("Discard your unsaved answer?", tableName: "Finalize"), discardTitle: Text("Discard", tableName: "Finalize"),
      keepEditingTitle: Text("Keep Editing", tableName: "Finalize"), onDiscard: { close() }
    )
    .onChange(of: model.isFormOpen, initial: true) { dismissGuard.hasUnsavedChanges = model.isFormOpen }
    .onChange(of: model.finalizing, initial: true) { dismissGuard.isBusy = model.finalizing }
    // FinalizeReviewDialog.tsx:213-217: Escape closes an open form before the dialog.
    .onKeyPress(.escape) {
      guard model.isFormOpen else { return .ignored }
      model.closeForms()
      return .handled
    }
    .task(id: generation) {
      let (store, query) = (context.store, FinalizeReviewScreenQuery(novel: context.novel, chapter: chapter))
      await screen.run { store.observe(FinalizeReviewScreen.self, query) }
    }
    .task(id: generation) {
      let (store, query) = (context.store, FinalizeReadinessQuery(novel: context.novel, chapter: chapter))
      await readiness.run { store.observe(FinalizeReadiness.self, query) }
    }
    .task(id: presentation?.phase == .preparing) {
      stuck = false
      guard presentation?.phase == .preparing, (try? await Task.sleep(for: FinalizePresentation.stuckAfter)) != nil else { return }
      stuck = true
    }
    .alert(Text(verbatim: failure?.headline ?? ""), isPresented: isFailing, presenting: failure) { _ in
      Button {
        failure = nil
      } label: {
        Text("OK", tableName: "Finalize")
      }
    } message: { failure in
      if let detail = failure.detail { Text(verbatim: detail) }
    }
  }

  private var isFailing: Binding<Bool> {
    Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
  }

  private func requestClose() {
    guard dismissGuard.requestDismiss() else { return }
    close()
  }

  private func close() {
    model.closeForms()
    model.refusal = nil
    dismiss()
  }

  // finalize-review.ts:337-340
  private func title(_ presentation: FinalizePresentation?) -> Text {
    if presentation?.phase == .applied { return Text("Chapter \(chapter)'s Story Bible updates", tableName: "Finalize") }
    return Text("Finalize chapter \(chapter): what it changes in your Story Bible", tableName: "Finalize")
  }

  private func subtitle(_ presentation: FinalizePresentation?) -> Text? {
    guard let presentation, presentation.isReviewing else { return nil }
    return Text(verbatim: FinalizeReviewDisplay.subtitle(open: presentation.openConsequential))
  }

  private func confirm(_ presentation: FinalizePresentation?) -> ShadowSheetConfirm? {
    guard let presentation, presentation.offersFinalize else { return nil }
    let enabled = presentation.finalizeEnabled(deciding: model.deciding, finalizing: model.finalizing, formOpen: model.isFormOpen)
    return ShadowSheetConfirm(Text(verbatim: FinalizeReviewDisplay.finalizeTitle(kept: presentation.kept)), isDisabled: !enabled, submitShortcut: true) {
      Task { await model.finalize() }
    }
  }

  @ViewBuilder
  private func content(_ presentation: FinalizePresentation?) -> some View {
    switch screen.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 160)
    case .failed(let error):
      ShadowCallout(Text("Couldn't load the review", tableName: "Finalize"), message: error.text, intent: .danger) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Finalize")
        }
      }
    case .loaded:
      if let presentation { loaded(presentation) }
    }
  }

  @ViewBuilder
  private func loaded(_ presentation: FinalizePresentation) -> some View {
    phaseNotice(presentation)
    if presentation.isolated && (presentation.isReviewing || presentation.phase == .applied) {
      note(Text("This chapter is isolated, so the lines each update was read from are withheld here.", tableName: "Finalize"))
    }
    if presentation.reopened > 0 {
      ShadowCallout(
        Text("The updates were read again, and \(presentation.reopened) you answered changed", tableName: "Finalize"),
        message: Text("Your earlier answers were for what the first read proposed. Answer the changed updates again.", tableName: "Finalize"), intent: .warning
      ) { EmptyView() }
    }
    if let sets = presentation.twoSets { FinalizeTwoSetsNotice(chapter: chapter, sets: sets) }
    if presentation.isReviewing || presentation.phase == .applied { items(presentation) }
    if presentation.readinessUnavailable {
      ShadowCallout(Text("Couldn't check whether this chapter can be finalized", tableName: "Finalize"), intent: .danger) { EmptyView() }
    }
    if !presentation.blockers.isEmpty { FinalizeBlockerList(chapter: chapter, blockers: presentation.blockers) }
    if let refusal = model.refusal { ShadowCallout(Text("Couldn't finalize", tableName: "Finalize"), message: refusal.text, intent: .danger) { EmptyView() } }
    if presentation.isReviewing && !presentation.autoKeepChoices.isEmpty { autoKeep(presentation) }
  }

  @ViewBuilder
  private func phaseNotice(_ presentation: FinalizePresentation) -> some View {
    switch presentation.phase {
    case .noDraft:
      ShadowContentUnavailable(Text("This chapter has no draft", tableName: "Finalize"), systemImage: "text.book.closed")
    case .unavailable:
      ShadowContentUnavailable(
        Text("Unavailable", tableName: "Finalize"), systemImage: "exclamationmark.triangle", message: presentation.unavailableMessage.map { Text(verbatim: $0) })
    case .unreviewed:
      ShadowCallout(
        Text("This chapter has no Story Bible review yet", tableName: "Finalize"),
        message: Text("Approve it, and its Story Bible updates are read from the version you approved.", tableName: "Finalize"), intent: .info
      ) { EmptyView() }
    case .preparing:
      HStack(spacing: Spacing.space3) {
        ProgressView().controlSize(.small)
        Text("Reading the Story Bible updates from the version you approved…", tableName: "Finalize").shadowFont(.body)
        if presentation.offersReadAgain(stuck: stuck) { readAgain }
      }
      note(autoFinalizeNote(presentation))
    case .failed(let failure):
      // FinalizeReviewDialog.tsx:269-277 with the job's own error in JobsErrors' words
      ShadowCallout(
        Text("Reading the updates from this chapter failed", tableName: "Finalize"), message: Text(verbatim: JobsErrors.failure(failure)), intent: .danger
      ) { readAgain }
    case .invalidated:
      ShadowCallout(
        Text("The text changed since you approved it", tableName: "Finalize"),
        message: Text("This review was read from an earlier version. Approve the chapter again to review what the new version changes.", tableName: "Finalize"),
        intent: .warning
      ) { EmptyView() }
    case .applied:
      ShadowCallout(
        model.finalized ? Text("Chapter \(chapter) is final", tableName: "Finalize") : Text("These updates are in the Story Bible", tableName: "Finalize"),
        message: Text("They were applied when chapter \(chapter) was finalized.", tableName: "Finalize"), intent: .success
      ) { EmptyView() }
    case .answering, .answered, .finalizable:
      EmptyView()
    }
  }

  private func autoFinalizeNote(_ presentation: FinalizePresentation) -> Text {
    guard presentation.finalizesOnItsOwn else { return Text("This chapter is isolated, so it becomes final only when you finalize it.", tableName: "Finalize") }
    return Text("If nothing needs your call, the chapter becomes final on its own.", tableName: "Finalize")
  }

  private var readAgain: some View {
    Button {
      Task { failure = await readAgainNow() }
    } label: {
      Text("Read Again", tableName: "Finalize")
    }
  }

  private func readAgainNow() async -> PresentedError? {
    guard let runtime = runtimes.existing(for: context.store) else { return JobsErrors.notRunningHere }
    let found: EntityRef?
    do throws(DomainError) {
      found = try await context.store.finalizeReviewJob(novel: context.novel, chapter: chapter)
    } catch {
      return JobsErrors.presented(error)
    }
    guard let job = found else { return JobsErrors.readNeedsApproval }
    return await runtime.retryRead(novel: context.novel, chapter: chapter, shown: job)
  }

  @ViewBuilder
  private func items(_ presentation: FinalizePresentation) -> some View {
    let readOnly = presentation.phase == .applied
    if !presentation.consequential.isEmpty {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        eyebrow(Text("Needs your call · \(presentation.openConsequential) of \(presentation.consequential.count)", tableName: "Finalize"))
        ForEach(presentation.consequential, id: \.key) { item in
          FinalizeReviewItemCard(item: item, model: model, readOnly: readOnly)
        }
      }
    }
    if !presentation.routine.isEmpty { routine(presentation, readOnly: readOnly) }
    if presentation.consequential.isEmpty && presentation.routine.isEmpty {
      note(Text("This chapter changes nothing in the Story Bible.", tableName: "Finalize"))
    }
    if presentation.isReviewing { disclosure(presentation) }
  }

  private func routine(_ presentation: FinalizePresentation, readOnly: Bool) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        DisclosureGroup(isExpanded: $routineOpen) {
          VStack(alignment: .leading, spacing: Spacing.space3) {
            ForEach(presentation.routine, id: \.key) { item in
              FinalizeRoutineRow(item: item, model: model, readOnly: readOnly)
            }
          }
          .padding(.top, Spacing.space2)
        } label: {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text("Routine · \(presentation.routine.count)", tableName: "Finalize").shadowFont(.subheadline)
            Text("Where people are, who appeared, small world details, promises that moved", tableName: "Finalize")
              .shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
        }
        if !readOnly {
          Button {
            Task { failure = await model.keepRoutine() }
          } label: {
            Text(verbatim: FinalizeReviewDisplay.keepAllTitle(presentation.routine))
          }
          .buttonStyle(.bordered)
          .disabled(model.deciding || presentation.openRoutine == 0)
        }
      }
    }
  }

  // FinalizeReviewDialog.tsx:418-438 with finalize-review.service.ts:159-168
  private func disclosure(_ presentation: FinalizePresentation) -> some View {
    let findings = FinalizeReviewDisplay.disclosures(presentation.review?.items ?? [])
    return VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space2) {
        Group {
          if findings.isEmpty {
            Text("No unplanned disclosure detected", tableName: "Finalize").foregroundStyle(ShadowColor.successText)
          } else {
            Text("\(findings.count) possible unplanned disclosures", tableName: "Finalize").foregroundStyle(ShadowColor.warningText)
          }
        }
        .shadowFont(.footnote)
        Button {
          checkedOpen.toggle()
        } label: {
          Text("What Was Checked", tableName: "Finalize")
        }
        .buttonStyle(.borderless)
      }
      ForEach(findings, id: \.self) { finding in note(Text(verbatim: finding)) }
      if checkedOpen {
        note(
          Text(
            "The updates read from the version you approved were checked against what the plan still keeps locked at this chapter. It's a model reading, so “nothing detected” is not a guarantee.",
            tableName: "Finalize"))
      }
    }
  }

  // FinalizeReviewDialog.tsx:464-477
  private func autoKeep(_ presentation: FinalizePresentation) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Keep automatically from now on:", tableName: "Finalize").shadowFont(.subheadline)
      ForEach(presentation.autoKeepChoices, id: \.self) { category in
        Toggle(isOn: autoKeepBinding(category, current: presentation.autoKeep)) { Text(verbatim: FinalizeReviewDisplay.autoKeep(category)) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Keep automatically from now on", tableName: "Finalize"))
  }

  private func autoKeepBinding(_ category: FinalizeCategory, current: [FinalizeCategory]) -> Binding<Bool> {
    Binding(
      get: { current.contains(category) },
      set: { on in Task { failure = await model.setAutoKeep(category, on: on, current: current) } })
  }

  private func eyebrow(_ text: Text) -> some View {
    text.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).textCase(.uppercase)
  }

  private func note(_ text: Text) -> some View {
    text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
  }
}

struct FinalizeBlockerList: View {
  let chapter: Int
  let blockers: [String]

  var body: some View {
    ShadowCallout(Text("Chapter \(chapter) can't be finalized yet", tableName: "Finalize"), intent: .warning) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        ForEach(blockers.indices, id: \.self) { index in
          Label(title: { Text(verbatim: blockers[index]) }, icon: { Image(systemName: "circle.fill").imageScale(.small) }).shadowFont(.footnote)
        }
      }
    }
  }
}
