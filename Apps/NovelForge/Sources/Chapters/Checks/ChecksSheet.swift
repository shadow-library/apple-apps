import CryptoKit
import Foundation
import NovelForgeCore
import ShadowAI
import ShadowDesignSystem
import ShadowJobs
import ShadowStore
import SwiftUI

/// apps/novel-forge-web/src/features/chapter-workspace/ChecksDrawer.tsx:1-100 with use-review-jobs.ts:9-34: the drawer over the chapter, the reviews read from the
/// store and the review jobs read from the chapter's jobs. The reference's "Repair with AI" and "Regenerate chapter" held actions (ChecksDrawer.tsx:103-169)
/// belong to the generation and revise screens and are not offered here.
struct ChecksSheet: View {
  let context: NovelContext
  let chapter: Int
  let isApproved: Bool
  let reloadToken: String
  @Environment(JobRuntimes.self) private var runtimes
  @Environment(AIServices.self) private var services
  @Environment(\.dismiss) private var dismiss
  @State private var model: ChecksModel
  @State private var jobs = ReadObserver<ChapterJobBoard>()
  @State private var reread = 0
  @State private var failure: PresentedError?
  @State private var consent: AIConsentRequest?

  private static let fallbackClock = LeaseClock(trusted: nil)

  static func reloadToken(_ body: ChapterContent.Body) -> String {
    switch body {
    case .draft(let draft): draft.revision
    case .final(let final): SHA256.hash(data: Data(final.body.utf8)).map { String(format: "%02x", $0) }.joined()
    case .missing, .unreadable: ""
    }
  }

  init(context: NovelContext, chapter: Int, isApproved: Bool, reloadToken: String) {
    self.context = context
    self.chapter = chapter
    self.isApproved = isApproved
    self.reloadToken = reloadToken
    _model = State(initialValue: ChecksModel(context: context, chapter: chapter))
  }

  var body: some View {
    let runtime = runtimes.existing(for: context.store)
    let clock = runtime?.clock ?? Self.fallbackClock
    let status = ChapterWorkspaceStatus(row: nil, board: jobs.state.value, replica: context.store.replica, standing: runtime?.standing ?? .starting)
    let lines = ChecksDisplay.reviewJobs(status.lines)
    let phases = Dictionary(uniqueKeysWithValues: ChecksDisplay.kinds.compactMap { kind in ChecksDisplay.phase(lines, of: kind).map { (kind, $0) } })
    content(status: status, lines: lines, phases: phases, runtime: runtime)
      .shadowSheetHeader(
        Text("Checks", tableName: "Checks"), subtitle: Text("Chapter \(chapter)", tableName: "Checks"),
        cancel: ShadowSheetCancel(Text("Done", tableName: "Checks"), systemImage: "checkmark") { dismiss() }
      )
      .shadowSheetStyle(.full)
      .task(id: reloadToken) { await model.load() }
      .onChange(of: phases) { Task { await model.load() } }
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
      .alert(Text(verbatim: failure?.headline ?? ""), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }), presenting: failure) { _ in
        Button {
          failure = nil
        } label: {
          Text("OK", tableName: "Checks")
        }
      } message: { failure in
        if let detail = failure.detail { Text(verbatim: detail) }
      }
      .aiConsentSheet($consent, services: services, store: context.store) { runtime?.consentAllowed() }
  }

  @ViewBuilder
  private func content(status: ChapterWorkspaceStatus, lines: [ChapterJobLine], phases: [ChapterReviewKind: ReviewJobPhase], runtime: JobRuntime?) -> some View {
    switch model.reviews {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 240)
    case .failed(let error) where model.reviews.value == nil:
      ShadowContentUnavailable(Text("Unavailable", tableName: "Checks"), kind: .error, message: error.text) {
        Button {
          Task { await model.load() }
        } label: {
          Text("Try Again", tableName: "Checks")
        }
      }
    case .loaded, .failed:
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          notices(status: status, lines: lines, runtime: runtime)
          ChecksPanel(
            model: model, phases: phases, jobsUnavailable: status.jobsUnavailable || isFailed, isApproved: isApproved,
            run: { kind, pace in start(kind, pace: pace, runtime: runtime) })
        }
        .padding(Spacing.space6)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
    }
  }

  private var isFailed: Bool {
    guard case .failed = jobs.state else { return false }
    return true
  }

  @ViewBuilder
  private func notices(status: ChapterWorkspaceStatus, lines: [ChapterJobLine], runtime: JobRuntime?) -> some View {
    if let refusal = model.refusal {
      ShadowCallout(Text(verbatim: refusal.headline), message: refusal.detail.map { Text(verbatim: $0) }, intent: .danger) { EmptyView() }
    }
    if model.elsewhere {
      ShadowCallout(Text("Another device is running this check.", tableName: "Checks"), intent: .info) { EmptyView() }
    }
    ForEach(lines) { line in
      ShadowCallout(
        JobDisplay.title(line), message: JobDisplay.message(line), intent: JobDisplay.intent(line)
      ) {
        if let runtime { actions(line, runtime: runtime) }
      }
    }
  }

  @ViewBuilder
  private func actions(_ line: ChapterJobLine, runtime: JobRuntime) -> some View {
    HStack(spacing: Spacing.space2) {
      ForEach(line.actions, id: \.self) { action in
        switch action {
        case .runHere:
          Button {
            Task { failure = await runtime.runHere(line.job) }
          } label: {
            JobDisplay.runHere
          }
        case .resume:
          Button {
            Task { failure = await runtime.resume(line.job) }
          } label: {
            JobDisplay.resume
          }
        case .allow:
          Button {
            consent = runtime.consentNeeded
          } label: {
            Text("Review Permission…", tableName: "Checks")
          }
        case .cancel:
          Button(role: .destructive) {
            Task { failure = await runtime.cancel(line.job) }
          } label: {
            if line.isRunning { Text("Stop", tableName: "Checks") } else { Text("Cancel", tableName: "Checks") }
          }
        case .tryAgain:
          Button {
            Task { failure = await runtime.tryAgain(line.job) }
          } label: {
            Text("Try Again", tableName: "Checks")
          }
        case .retryRead: EmptyView()
        }
      }
    }
    .disabled(runtime.pending.contains(line.job))
  }

  private func start(_ kind: ChapterReviewKind, pace: Pace?, runtime: JobRuntime?) {
    let startsHere = runtime?.startsWhenAsked(.review) ?? false
    let request = ChecksModel.requester(store: context.store, novel: context.novel, chapter: chapter, engine: runtime?.engine, startsHere: startsHere) {
      runtime?.follow($0)
    }
    Task { await model.run(kind, pace: pace, runsJobs: runtime?.runsJobs == true, using: request) }
  }
}
