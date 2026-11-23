import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowDesignSystem
import ShadowJobs
import ShadowStore
import SwiftUI

/// apps/novel-forge-web/src/features/chapter-workspace/WorkspaceStrip.tsx:14-24 with the status pill of chapters/ChapterWorkspace.tsx:288-298: the chapter's
/// status chip, then a line per job of the chapter in flight or failed, with its actions.
struct ChapterWorkspaceStrip: View {
  let context: NovelContext
  let chapter: Int
  let row: ChapterRow?
  @Environment(JobRuntimes.self) private var runtimes
  @Environment(AIServices.self) private var services
  @State private var jobs = ReadObserver<ChapterJobBoard>()
  @State private var reread = 0
  @State private var stopping: ChapterJobLine?
  @State private var failure: PresentedError?
  @State private var consent: AIConsentRequest?
  @State private var gate = ProviderGate()

  private static let fallbackClock = LeaseClock(trusted: nil)

  var body: some View {
    let runtime = runtimes.existing(for: context.store)
    let clock = runtime?.clock ?? Self.fallbackClock
    let status = ChapterWorkspaceStatus(row: row, board: jobs.state.value, replica: context.store.replica, standing: runtime?.standing ?? .starting)
    VStack(alignment: .leading, spacing: Spacing.space3) {
      let chip = JobDisplay.chip(status.status)
      ShadowBadge(Text(verbatim: chip.label), intent: chip.intent, systemImage: chip.systemImage)
      ForEach(status.lines) { line in
        ShadowCallout(JobDisplay.title(line), message: JobDisplay.message(line), intent: JobDisplay.intent(line)) {
          if let runtime { actions(line, runtime: runtime) }
        }
        if runtime?.needsAppOpen(line.job) == true { note(ContinuedProcessingText.keepOpen) }
      }
      if status.jobsUnavailable || isFailed { note(Text("This chapter's jobs can't be read on this device right now.", tableName: "Jobs")) }
      if let runtime { modeNote(runtime.mode) }
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
    .confirmationDialog(Text("Stop this job?", tableName: "Jobs"), isPresented: isStopping, presenting: stopping) { line in
      Button(role: .destructive) {
        Task { failure = await runtime?.cancel(line.job) }
      } label: {
        Text("Stop Job", tableName: "Jobs")
      }
      Button(role: .cancel) {
      } label: {
        Text("Keep It", tableName: "Jobs")
      }
    } message: { _ in
      Text("It stops on every device. You can ask for it again later.", tableName: "Jobs")
    }
    .alert(Text(verbatim: failure?.headline ?? ""), isPresented: isFailing, presenting: failure) { _ in
      Button {
        failure = nil
      } label: {
        Text("OK", tableName: "Jobs")
      }
    } message: { failure in
      if let detail = failure.detail { Text(verbatim: detail) }
    }
    .aiConsentSheet($consent, services: services, store: context.store) { runtime?.consentAllowed() }
    .aiProviderSheet(isPresented: $gate.needsProvider, services: services) { Task { await gate.providerConnected() } }
  }

  private func startingHere(_ action: @escaping @MainActor () async -> PresentedError?) {
    Task { await gate.perform(providerReady: services.isReadyForStandardCalls) { failure = await action() } }
  }

  private var isStopping: Binding<Bool> {
    Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })
  }

  private var isFailing: Binding<Bool> {
    Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
  }

  private var isFailed: Bool {
    guard case .failed = jobs.state else { return false }
    return true
  }

  @ViewBuilder
  private func modeNote(_ mode: JobRuntime.Mode) -> some View {
    switch mode {
    case .starting, .running: EmptyView()
    case .elsewhere:
      note(Text("Another copy of Novel Forge on this Mac is running this library's jobs, so this copy shows them but doesn't run them.", tableName: "Jobs"))
    case .unavailable(let error): note(error.text)
    }
  }

  private func note(_ text: Text) -> some View {
    text.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
  }

  @ViewBuilder
  private func actions(_ line: ChapterJobLine, runtime: JobRuntime) -> some View {
    if !line.actions.isEmpty {
      HStack(spacing: Spacing.space2) {
        ForEach(line.actions, id: \.self) { action in
          button(action, line: line, runtime: runtime)
        }
      }
      .disabled(runtime.pending.contains(line.job))
    }
  }

  @ViewBuilder
  private func button(_ action: ChapterJobLine.Action, line: ChapterJobLine, runtime: JobRuntime) -> some View {
    switch action {
    case .runHere:
      Button {
        startingHere { await runtime.runHere(line.job) }
      } label: {
        JobDisplay.runHere
      }
    case .resume:
      Button {
        startingHere { await runtime.resume(line.job) }
      } label: {
        JobDisplay.resume
      }
    case .allow:
      Button {
        consent = runtime.consentNeeded
      } label: {
        Text("Review Permission…", tableName: "Jobs")
      }
    case .cancel:
      Button(role: .destructive) {
        stopping = line
      } label: {
        if line.isRunning { Text("Stop", tableName: "Jobs") } else { Text("Cancel", tableName: "Jobs") }
      }
    case .tryAgain:
      Button {
        startingHere { await runtime.tryAgain(line.job) }
      } label: {
        Text("Try Again", tableName: "Jobs")
      }
    case .retryRead:
      Button {
        startingHere { await runtime.retryRead(novel: context.novel, chapter: chapter, shown: line.job) }
      } label: {
        Text("Read Again", tableName: "Jobs")
      }
    }
  }
}
