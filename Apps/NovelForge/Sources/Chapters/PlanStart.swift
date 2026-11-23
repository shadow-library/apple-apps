import Foundation
import NovelForgeCore
import Observation
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowDesignSystem
import ShadowJobs
import ShadowStore
import SwiftUI

/// "Plan next chapter" (apps/novel-forge-web/src/features/plan-card/PlanStart.tsx:34-124, opened from the "Plan chapter N" chip of
/// features/chat/ChatColumn.tsx:556-559, 732-751, 997-1010), then the plan job's progress and the plan cards it stages. The reference sends the author's
/// line to the chat; natively it asks `JobEngine.requestPlan` for the job, which the runtime's backlog runs, and the card it stages has no chat, so its
/// only place in a thread is here, where its Waiting on you line scrolls (`reveal`). Not ported: the chat's suggested directions (ChatColumn passes none),
/// "Write it myself" (an empty chapter in the editor), and "Write the plan myself", whose empty card can't be filled in until a staged card can be edited.
struct PlanStart: View {
  let context: NovelContext
  /// Changes each time Waiting on you asks for the plan cards.
  let reveal: Int
  /// chat-view.ts:631: the chip waits while a turn runs or Forge's question waits for an answer.
  let isBusy: Bool
  @Environment(JobRuntimes.self) private var runtimes
  @Environment(AIServices.self) private var services
  @State private var model: PlanStartModel
  @State private var presenter = ChatCardsPresenter()
  @State private var reread = 0
  @State private var stopping: ChapterJobLine?
  @State private var failure: PresentedError?
  @State private var consent: AIConsentRequest?
  @State private var gate = ProviderGate()

  private static let fallbackClock = LeaseClock(trusted: nil)
  private static let cardsAnchor = "plan-start-cards"

  init(context: NovelContext, reveal: Int, isBusy: Bool) {
    self.context = context
    self.reveal = reveal
    self.isBusy = isBusy
    _model = State(initialValue: PlanStartModel(context: context))
  }

  var body: some View {
    let runtime = runtimes.existing(for: context.store)
    let clock = runtime?.clock ?? Self.fallbackClock
    ScrollViewReader { proxy in
      content(runtime: runtime)
        .onChange(of: reveal) { withAnimation { proxy.scrollTo(Self.cardsAnchor, anchor: .top) } }
    }
    .task(id: reread) { await model.observe(now: clock.now()) }
    .task(id: model.state.value?.changesAt) {
      guard let changesAt = model.state.value?.changesAt else { return }
      let delay = max(0, changesAt.timeIntervalSince(clock.now().date))
      guard (try? await Task.sleep(for: .seconds(delay) + .milliseconds(1))) != nil else { return }
      reread += 1
    }
    .confirmationDialog(Text("Discard this plan?", tableName: "PlanCard"), isPresented: isDiscarding, titleVisibility: .visible) {
      Button(role: .destructive) {
        guard let card = presenter.discarding else { return }
        Task { await card.discard() }
      } label: {
        Text("Discard", tableName: "PlanCard")
      }
      .shadowDestructiveDialogAction()
    } message: {
      Text("Nothing in it becomes the chapter's plan. You can plan the chapter again.", tableName: "PlanCard")
    }
    .confirmationDialog(Text("Stop planning?", tableName: "PlanCard"), isPresented: isStopping, presenting: stopping) { line in
      Button(role: .destructive) {
        failure = nil
        Task { failure = await runtime?.cancel(line.job) }
      } label: {
        Text("Stop Job", tableName: "PlanCard")
      }
      Button(role: .cancel) {
      } label: {
        Text("Keep It", tableName: "PlanCard")
      }
    } message: { _ in
      Text("It stops on every device. You can plan the chapter again later.", tableName: "PlanCard")
    }
    .aiConsentSheet($consent, services: services, store: context.store) { runtime?.consentAllowed() }
    .aiProviderSheet(isPresented: $gate.needsProvider, services: services) { Task { await gate.providerConnected() } }
    .aiProviderSheet(isPresented: $model.needsProvider, services: services) {
      let runtime = runtimes.existing(for: context.store)
      Task { await model.plan(using: requester(runtime), providerReady: services.isReady(toStart: .plan, on: runtime)) }
    }
  }

  private func content(runtime: JobRuntime?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      switch model.state {
      case .loading:
        EmptyView()
      case .failed(let error):
        ShadowCallout(Text("Planning the next chapter is unavailable", tableName: "PlanCard"), message: error.text, intent: .warning) {
          Button {
            reread += 1
          } label: {
            Text("Try Again", tableName: "PlanCard")
          }
        }
      case .loaded(let snapshot):
        loaded(snapshot, runtime: runtime)
      }
    }
  }

  @ViewBuilder
  private func loaded(_ snapshot: PlanStartSnapshot, runtime: JobRuntime?) -> some View {
    if let next = snapshot.next {
      if model.isOpen {
        panel(next, runtime: runtime)
      } else if snapshot.offersChip(isBusy: isBusy) {
        chip(next)
      }
    } else {
      note(Text("Which chapter comes next can't be read on this device right now.", tableName: "PlanCard"))
    }
    jobLines(snapshot, runtime: runtime)
    if snapshot.cardsUnavailable {
      note(Text("Plans waiting on you are not up to date on this device yet.", tableName: "PlanCard"))
    }
    VStack(alignment: .leading, spacing: Spacing.space3) {
      ForEach(model.cards, id: \.self) { proposal in
        PlanStartCard(proposal: proposal, context: context, presenter: presenter).id(proposal)
      }
    }
    .id(Self.cardsAnchor)
    if let failure {
      ShadowCallout(Text(verbatim: failure.headline), message: failure.detail.map { Text(verbatim: $0) }, intent: .warning) { EmptyView() }
    }
  }

  // ChatColumn.tsx:558, chat-view.ts:537
  private func chip(_ next: Int) -> some View {
    Button {
      failure = nil
      model.open()
    } label: {
      Label {
        Text("Plan chapter \(next)", tableName: "PlanCard")
      } icon: {
        Image(systemName: "list.bullet.rectangle")
      }
    }
    .buttonStyle(.bordered)
  }

  // PlanStart.tsx:39-65 and :113-116, with ChatColumn.tsx:997-1001 ("Not now")
  private func panel(_ next: Int, runtime: JobRuntime?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("What happens in chapter \(next)", tableName: "PlanCard").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      TextField(text: $model.direction, prompt: Text("Optional. She sells the lamp, and regrets it by nightfall.", tableName: "PlanCard"), axis: .vertical) {
        Text("What happens in chapter \(next)", tableName: "PlanCard")
      }
      .lineLimit(2...5)
      .shadowField()
      .disabled(model.isRequesting)
      HStack(spacing: Spacing.space2) {
        Button {
          failure = nil
          Task { await model.plan(using: requester(runtime), providerReady: services.isReady(toStart: .plan, on: runtime)) }
        } label: {
          Text("Make the Plan", tableName: "PlanCard")
        }
        .buttonStyle(.borderedProminent)
        Button {
          model.close()
        } label: {
          Text("Not Now", tableName: "PlanCard")
        }
        .buttonStyle(.borderless)
        if model.isRequesting { ProgressView().controlSize(.small) }
      }
      .disabled(model.isRequesting)
      note(Text("No directions, no questions — straight to a plan card.", tableName: "PlanCard"))
      if let refusal = model.refusal {
        ShadowCallout(Text(verbatim: refusal.headline), message: refusal.detail.map { Text(verbatim: $0) }, intent: .warning) { EmptyView() }
      }
    }
    .padding(Spacing.space4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(ShadowColor.borderSubtle))
  }

  @ViewBuilder
  private func jobLines(_ snapshot: PlanStartSnapshot, runtime: JobRuntime?) -> some View {
    let status = ChapterWorkspaceStatus(
      row: nil, jobs: .available(snapshot.jobs), placements: snapshot.placements, replica: context.store.replica, standing: runtime?.standing ?? .starting)
    ForEach(status.lines) { line in
      ShadowCallout(JobDisplay.title(line.kind), message: JobDisplay.message(line), intent: JobDisplay.intent(line)) {
        if let runtime { actions(line, runtime: runtime) }
      }
      if runtime?.needsAppOpen(line.job) == true { note(ContinuedProcessingText.keepOpen) }
    }
    if snapshot.jobsUnavailable {
      note(Text("Whether a plan is being made can't be read on this device right now.", tableName: "PlanCard"))
    }
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
        failure = nil
        consent = runtime.consentNeeded
      } label: {
        Text("Review Permission…", tableName: "PlanCard")
      }
    case .cancel:
      Button(role: .destructive) {
        stopping = line
      } label: {
        if line.isRunning { Text("Stop", tableName: "PlanCard") } else { Text("Cancel", tableName: "PlanCard") }
      }
    case .tryAgain:
      Button {
        startingHere { await runtime.tryAgain(line.job) }
      } label: {
        Text("Try Again", tableName: "PlanCard")
      }
    case .retryRead:
      EmptyView()
    }
  }

  /// chat-view.ts:625-629: Forge's newest reply asked a question the author has not written after.
  static func awaitsAnswer(_ messages: [ChatTranscriptMessage]) -> Bool {
    awaitsAnswer(
      marks: messages.compactMap { message in
        message.record.map { record in
          ChatTurnMark(position: message.position, isAuthor: record.role == .known(.user), asks: record.role == .known(.assistant) ? record.questionCard != nil : nil)
        }
      })
  }

  static func awaitsAnswer(marks: [ChatTurnMark]) -> Bool {
    guard let latest = marks.filter({ $0.asks != nil }).max(by: { $0.position < $1.position }), latest.asks == true else { return false }
    return !marks.contains { $0.isAuthor && $0.position > latest.position }
  }

  private func startingHere(_ action: @escaping @MainActor () async -> PresentedError?) {
    failure = nil
    Task { await gate.perform(providerReady: services.isReadyForStandardCalls) { failure = await action() } }
  }

  private func requester(_ runtime: JobRuntime?) -> PlanStartModel.Requester? {
    guard let engine = runtime?.engine else { return nil }
    return { request async throws(ChapterPlanError) in try await engine.requestPlan(request) }
  }

  private func note(_ text: Text) -> some View {
    text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
  }

  private var isDiscarding: Binding<Bool> {
    Binding(get: { presenter.discarding != nil }, set: { if !$0 { presenter.discarding = nil } })
  }

  private var isStopping: Binding<Bool> {
    Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })
  }
}

private struct PlanStartCard: View {
  @State private var model: ChatProposalCardModel
  private let presenter: ChatCardsPresenter

  init(proposal: UUID, context: NovelContext, presenter: ChatCardsPresenter) {
    self.presenter = presenter
    _model = State(initialValue: ChatProposalCardModel(proposal: proposal, context: context, writer: CoreChatProposalWriter(context: context)))
  }

  var body: some View {
    ChatProposalCard(model: model, presenter: presenter)
  }
}

/// The next chapter, its plan jobs and those still open for chapters passed since, and the plan cards waiting with no chat, read in one transaction.
nonisolated struct PlanStartSnapshot: Equatable, Sendable {
  /// Nil while the chapters' derived state is faulted here.
  let next: Int?
  let jobs: [ChapterJob]
  let placements: JobPlacements
  /// The next chapter's jobs, or the novel's job activity, are faulted here: the lines shown may be missing some.
  let jobsUnavailable: Bool
  /// A plan job for the next chapter is queued or running.
  let isPlanning: Bool
  let changesAt: Date?
  /// Pending and conflicted chapter_plan cards with no chat, oldest staged first.
  let cards: [UUID]
  let cardsUnavailable: Bool

  static func load(novel: UUID, replica: ReplicaID, now: LeaseInstant, in transaction: ReadTransaction) throws -> PlanStartSnapshot {
    let next = try ChapterList.load(novel, in: transaction).rows.value.map(Self.nextWritable)
    let chapterJobs = try next.map { try ChapterJobs.load(ChapterJobsQuery(novel: novel, chapter: $0, now: now), in: transaction) }
    var jobs = (chapterJobs?.jobs.value ?? []).filter { $0.kind == .known(.plan) }
    let isPlanning = jobs.contains(where: Self.isOpen)
    var changes = [chapterJobs?.changesAt].compactMap { $0 }
    let activity = try JobActivity.load(JobActivityQuery(novel: novel, now: now), in: transaction).entries
    let open = (activity.value ?? []).filter { $0.kind == .known(.plan) && [.queued, .running].contains($0.status.phase) }
    for chapter in Set(open.compactMap(\.chapter)).subtracting([next].compactMap { $0 }).sorted() {
      let other = try ChapterJobs.load(ChapterJobsQuery(novel: novel, chapter: chapter, now: now), in: transaction)
      changes += [other.changesAt].compactMap { $0 }
      jobs += (other.jobs.value ?? []).filter { $0.kind == .known(.plan) && Self.isOpen($0) }
    }
    let placements = try JobPlacements.load(JobPlacementQuery(jobs: jobs.map(\.job), replica: replica, now: now), in: transaction)
    changes += [placements.changesAt].compactMap { $0 }
    let waiting = try ChatWaitingOnYou.load(novel, in: transaction).contents
    let plans = ((waiting.value?.cards ?? []) + (waiting.value?.conflicted ?? [])).filter { $0.session == .none && $0.state.kind == .known(.chapterPlan) }
    let cards = plans.sorted { $0.state.staged == $1.state.staged ? $0.state.ref < $1.state.ref : $0.state.staged < $1.state.staged }.map(\.state.proposal)
    return PlanStartSnapshot(
      next: next, jobs: jobs, placements: placements, jobsUnavailable: chapterJobs?.jobs.isUnavailable == true || activity.isUnavailable, isPlanning: isPlanning,
      changesAt: changes.min(), cards: cards, cardsUnavailable: waiting.isUnavailable)
  }

  /// ChatColumn.tsx:322-325 with chat-view.ts:631: the chip waits while the chat is busy and while the next chapter is being planned.
  func offersChip(isBusy: Bool) -> Bool { next != nil && !isBusy && !isPlanning }

  private static func isOpen(_ job: ChapterJob) -> Bool { [.queued, .running].contains(job.status.phase) }

  /// apps/novel-forge-server/src/common/next-chapter.ts:11 over the chapters with a draft and the final ones, as PlanRequests reads it.
  static func nextWritable(_ rows: [ChapterRow]) -> Int {
    ChapterSequence.nextWritable(draftChapters: rows.filter { $0.stage != .planned }.map(\.chapter), finalizedChapters: rows.filter { $0.stage == .final }.map(\.chapter))
  }
}

/// A transcript message as the chip reads it: its place, whether the author wrote it, and for Forge's replies whether it asked a question.
nonisolated struct ChatTurnMark: Equatable, Sendable {
  let position: Int
  let isAuthor: Bool
  let asks: Bool?
}

@MainActor
@Observable
final class PlanStartModel {
  typealias Requester = @Sendable (ChapterPlanJobRequest) async throws(ChapterPlanError) -> ChapterPlanReceipt

  let context: NovelContext
  private(set) var isOpen = false
  var direction = ""
  private(set) var isRequesting = false
  var needsProvider = false
  private(set) var refusal: PresentedError?
  /// PlanCard.tsx:91: every plan card listed here since the panel appeared, so a saved or discarded one stays with its status, as in the reference's thread.
  private(set) var cards: [UUID] = []
  private let observer = ReadObserver<PlanStartSnapshot>()

  init(context: NovelContext) {
    self.context = context
  }

  var state: Loadable<PlanStartSnapshot> { observer.state }

  func observe(now: LeaseInstant) async {
    let (store, novel) = (context.store, context.novel)
    let replica = store.replica
    await observer.run(
      { store.observeReads { transaction in try PlanStartSnapshot.load(novel: novel, replica: replica, now: now, in: transaction) } },
      onValue: { [weak self] snapshot in self?.keep(snapshot.cards) })
  }

  private func keep(_ waiting: [UUID]) {
    cards += waiting.filter { !cards.contains($0) }
  }

  func open() {
    isOpen = true
    refusal = nil
  }

  func close() {
    isOpen = false
    refusal = nil
  }

  /// PlanStart.tsx:45-48: the chapter shown as next, with the author's line, if any, as their own intent. A refusal keeps the panel and the line open.
  func plan(using requester: Requester?, providerReady: Bool = true) async {
    guard !isRequesting, let chapter = state.value?.next else { return }
    guard let requester else {
      refusal = JobsErrors.notRunningHere
      return
    }
    guard providerReady else {
      needsProvider = true
      return
    }
    let words = direction.trimmingCharacters(in: .whitespacesAndNewlines)
    let steer: ChapterPlanSteer = words.isEmpty ? .none : .author(words)
    isRequesting = true
    refusal = nil
    defer { isRequesting = false }
    do throws(ChapterPlanError) {
      _ = try await requester(ChapterPlanJobRequest(novel: context.novel, chapter: chapter, steer: steer))
      isOpen = false
      direction = ""
    } catch {
      refusal = PlanCardErrors.presented(error)
    }
  }
}
