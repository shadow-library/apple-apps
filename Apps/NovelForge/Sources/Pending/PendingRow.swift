import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowDesignSystem
import ShadowJobs
import ShadowStore
import SwiftUI

/// One thing waiting on the author, the same on the iPhone home and in the chat's tray: tapping it goes where it is settled, and a job's buttons act on this
/// device's runtime without leaving the list.
struct PendingRow: View {
  let item: PendingItem
  let context: NovelContext
  let actions: PendingActions
  let chats: ChatNovelModel?
  /// The chat on screen, when the row sits in its tray.
  var here: UUID?
  @Environment(NovelNavigator.self) private var navigator
  @Environment(JobRuntimes.self) private var runtimes

  var body: some View {
    let runtime = runtimes.existing(for: context.store)
    let destination = PendingDestination.of(item) { chats?.overview(of: $0) != nil }
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Button {
        if let destination { actions.open(destination, navigator: navigator, chats: chats) }
      } label: {
        summary
      }
      .buttonStyle(.plain)
      .disabled(destination == nil)
      .accessibilityHint(Text("Opens where you can settle it", tableName: "Pending"))
      buttons(runtime: runtime)
    }
    .contextMenu { menu(runtime: runtime) }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        PendingDisplay.chip(item)
        PendingDisplay.title(item).shadowFont(.callout).foregroundStyle(ShadowColor.textPrimary).lineLimit(2)
        Spacer(minLength: 0)
      }
      Text(verbatim: PendingDisplay.subtitle(item, chats: chats, here: here, now: Date())).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        .lineLimit(3)
      if let detail = PendingDisplay.detail(item) { detail.text.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func buttons(runtime: JobRuntime?) -> some View {
    switch item.kind {
    case .job(let job):
      let offered = PendingDisplay.actions(job)
      if !offered.isEmpty {
        HStack(spacing: Spacing.space2) {
          ForEach(offered, id: \.self) { action in
            Button {
              Task { await actions.perform(action, on: job, novel: context.novel, runtime: runtime) }
            } label: {
              PendingDisplay.label(action)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
        .disabled(runtime?.pending.contains(job.line.job) ?? true)
      }
    case .finalize(let chapter, _):
      Button {
        actions.finalizing = chapter
      } label: {
        Text("Review Updates", tableName: "Pending")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    case .chat(let chat):
      if case .actions(_, .faulted(_, true)) = chat.kind, case .proposal(let proposal) = chat.target, let tray = chats?.waiting {
        HStack(spacing: Spacing.space2) {
          Button {
            Task { await tray.retryActions(proposal) }
          } label: {
            Text("Try Again", tableName: "Pending")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(tray.retrying != nil)
          if tray.retrying == proposal { ProgressView().controlSize(.small) }
        }
        if let notice = tray.retryNotices[proposal] { notice.text.shadowFont(.caption).foregroundStyle(ShadowColor.warningText) }
      }
    case .review:
      EmptyView()
    }
  }

  @ViewBuilder
  private func menu(runtime: JobRuntime?) -> some View {
    if case .job(let job) = item.kind, job.line.actions.contains(.cancel) {
      Button(role: .destructive) {
        Task { await actions.perform(.cancel, on: job, novel: context.novel, runtime: runtime) }
      } label: {
        PendingDisplay.label(.cancel)
      }
    }
  }
}

extension View {
  /// The finalize dialog, the consent sheet, the stop confirmation and a refusal for the rows below.
  func pendingPresentations(_ actions: PendingActions, context: NovelContext) -> some View {
    modifier(PendingPresentations(actions: actions, context: context))
  }
}

private struct PendingPresentations: ViewModifier {
  @Bindable var actions: PendingActions
  let context: NovelContext
  @Environment(JobRuntimes.self) private var runtimes
  @Environment(AIServices.self) private var services

  func body(content: Content) -> some View {
    let runtime = runtimes.existing(for: context.store)
    content
      .sheet(item: finalizing) { chapter in FinalizeReviewDialog(context: context, chapter: chapter.id) }
      .confirmationDialog(Text("Cancel this job?", tableName: "Pending"), isPresented: isStopping, presenting: actions.stopping) { job in
        Button(role: .destructive) {
          Task { await actions.stop(job, runtime: runtime) }
        } label: {
          PendingDisplay.label(.cancel)
        }
        Button(role: .cancel) {
        } label: {
          Text("Keep It", tableName: "Pending")
        }
      } message: { _ in
        Text("It stops on every device. You can ask for it again later.", tableName: "Pending")
      }
      .alert(Text(verbatim: actions.failure?.headline ?? ""), isPresented: isFailing, presenting: actions.failure) { _ in
        Button {
          actions.failure = nil
        } label: {
          Text("OK", tableName: "Pending")
        }
      } message: { failure in
        if let detail = failure.detail { Text(verbatim: detail) }
      }
      .aiConsentSheet($actions.consent, services: services, store: context.store) { runtime?.consentAllowed() }
  }

  private var finalizing: Binding<PendingChapter?> {
    Binding(get: { actions.finalizing.map(PendingChapter.init) }, set: { actions.finalizing = $0?.id })
  }

  private var isStopping: Binding<Bool> {
    Binding(get: { actions.stopping != nil }, set: { if !$0 { actions.stopping = nil } })
  }

  private var isFailing: Binding<Bool> {
    Binding(get: { actions.failure != nil }, set: { if !$0 { actions.failure = nil } })
  }
}

private struct PendingChapter: Identifiable {
  let id: Int
}

extension View {
  /// Observes the novel's Waiting on you, read again when a lease lapses with no write and on Try Again.
  func pendingObservation(_ model: PendingModel, context: NovelContext, isActive: Bool = true) -> some View {
    modifier(PendingObservation(model: model, context: context, isActive: isActive))
  }
}

private struct PendingObservation: ViewModifier {
  let model: PendingModel
  let context: NovelContext
  let isActive: Bool
  @Environment(JobRuntimes.self) private var runtimes
  @State private var reread = 0

  private static let fallbackClock = LeaseClock(trusted: nil)

  func body(content: Content) -> some View {
    let clock = runtimes.existing(for: context.store)?.clock ?? Self.fallbackClock
    content
      .task(id: Key(novel: context.novel, reread: reread, generation: model.generation, isActive: isActive)) {
        guard isActive else { return }
        await model.observe(context, now: clock.now())
      }
      .task(id: isActive ? model.changesAt : nil) {
        guard let changesAt = model.changesAt, isActive else { return }
        let delay = max(0, changesAt.timeIntervalSince(clock.now().date))
        guard (try? await Task.sleep(for: .seconds(delay) + .milliseconds(1))) != nil else { return }
        reread += 1
      }
  }

  private struct Key: Hashable {
    let novel: UUID
    let reread: Int
    let generation: Int
    let isActive: Bool
  }
}
