import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowJobs
import ShadowStore
import SwiftUI

/// apps/novel-forge-web/src/components/nf/RegenerateChapter.tsx:20-54 and chapters/ChapterWorkspace.tsx:288-296 (the writing status and its Stop): generate or regenerate
/// the chapter, follow the run's steps and stop it.
struct GenerationControls: View {
  let context: NovelContext
  let chapter: Int
  let row: ChapterRow?
  @Environment(JobRuntimes.self) private var runtimes
  @Environment(AIServices.self) private var services
  @State private var jobs = ReadObserver<ChapterJobBoard>()
  @State private var model: GenerationModel
  @State private var reread = 0
  @State private var options: GenerationKind?

  private static let fallbackClock = LeaseClock(trusted: nil)

  init(context: NovelContext, chapter: Int, row: ChapterRow?) {
    self.context = context
    self.chapter = chapter
    self.row = row
    _model = State(initialValue: GenerationModel(novel: context.novel, chapter: chapter))
  }

  var body: some View {
    let runtime = runtimes.existing(for: context.store)
    let clock = runtime?.clock ?? Self.fallbackClock
    let status = ChapterWorkspaceStatus(row: row, board: jobs.state.value, replica: context.store.replica, standing: runtime?.standing ?? .starting)
    let line = status.lines.first { $0.kind == .generate && GenerationModel.isBusy($0) }
    Group {
      if row?.stage != .final {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          if let line { progress(line) }
          actions(busy: line != nil)
          notice
        }
      }
    }
    .task(id: reread) {
      let store = context.store
      let query = ChapterJobBoardQuery(novel: context.novel, chapter: chapter, replica: store.replica, now: clock.now())
      await jobs.run { store.observe(ChapterJobBoard.self, query) }
    }
    .task(id: jobs.state.value?.changesAt) {
      guard let changesAt = jobs.state.value?.changesAt else { return }
      let delay = max(0, changesAt.timeIntervalSince(clock.now().date))
      guard (try? await Task.sleep(for: .seconds(delay) + .milliseconds(1))) != nil else { return }
      reread += 1
    }
    .sheet(item: $options) { kind in
      GenerationOptionsSheet(kind: kind, chapter: chapter) { options in Task { await model.start(kind, options: options, runtime: runtimes.existing(for: context.store)) } }
    }
    .aiProviderSheet(isPresented: $model.needsProvider, services: services) { options = model.providerConnected() }
    .aiConsentSheet($model.consent, services: services, store: context.store) { model.consentAllowed(on: runtimes.existing(for: context.store)) }
    .alert(Text(verbatim: model.failure?.headline ?? ""), isPresented: isFailing, presenting: model.failure) { _ in
      Button {
        model.failure = nil
      } label: {
        Text("OK", tableName: "Generation")
      }
    } message: { failure in
      if let detail = failure.detail { Text(verbatim: detail) }
    }
  }

  private var hasDraft: Bool {
    guard let stage = row?.stage else { return false }
    return stage != .planned
  }

  private func actions(busy: Bool) -> some View {
    Button {
      let runtime = runtimes.existing(for: context.store)
      options = model.ask(hasDraft ? .regenerate : .generate, providerReady: services.isReady(toStart: .generate, on: runtime))
    } label: {
      Label(
        title: { if hasDraft { Text("Regenerate…", tableName: "Generation") } else { Text("Generate…", tableName: "Generation") } },
        icon: { Image(systemName: "sparkles") })
    }
    .disabled(busy || model.isStarting)
    .accessibilityIdentifier("generate-chapter")
  }

  @ViewBuilder
  private var notice: some View {
    switch model.notice {
    case .runningElsewhere?:
      note(Text("Another device is already writing this chapter.", tableName: "Generation"))
    case .waitingForConsent?:
      note(Text("Waiting for your permission to send this novel's text to the AI provider.", tableName: "Generation"))
    default: EmptyView()
    }
  }

  private func note(_ text: Text) -> some View {
    text.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
  }

  private func progress(_ line: ChapterJobLine) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      (line.isRunning ? JobDisplay.title(.generate) : JobDisplay.message(line)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      if line.isRunning { steps(line.step) }
    }
    .padding(Spacing.space3)
    .background(ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md))
  }

  private func steps(_ step: AttemptStep?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      ForEach(GenerationProgress.rows(at: step)) { row in
        Label(title: { GenerationDisplay.step(row.name).shadowFont(.footnote) }, icon: { Image(systemName: GenerationDisplay.icon(row.state)) })
          .foregroundStyle(row.state == .pending ? ShadowColor.textTertiary : row.state == .current ? ShadowColor.accent : ShadowColor.textSecondary)
      }
    }
  }

  private var isFailing: Binding<Bool> {
    Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
  }
}

extension GenerationKind: Identifiable {
  var id: Self { self }
}

enum GenerationDisplay {
  static func icon(_ state: GenerationStepRow.State) -> String {
    switch state {
    case .done: "checkmark.circle.fill"
    case .current: "circle.dotted"
    case .pending: "circle"
    }
  }

  static func step(_ name: String) -> Text {
    switch name {
    case "pin": Text("Preparing", tableName: "Generation")
    case "draft": Text("Drafting", tableName: "Generation")
    case "expand": Text("Expanding", tableName: "Generation")
    case "title": Text("Titling", tableName: "Generation")
    case "save": Text("Saving", tableName: "Generation")
    case "checks": Text("Checking", tableName: "Generation")
    case "judge": Text("Judging", tableName: "Generation")
    case "repair": Text("Repairing", tableName: "Generation")
    case "rewrite": Text("Rewriting", tableName: "Generation")
    case "finish": Text("Finishing", tableName: "Generation")
    default: Text(verbatim: name)
    }
  }
}
