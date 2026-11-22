import MemoirCore
import ShadowAI
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

struct AskView: View {
  let context: MemoirScreenContext
  @Environment(MemoirInsights.self) private var insights
  @Environment(AIServices.self) private var ai

  init(context: MemoirScreenContext) {
    self.context = context
  }

  var body: some View {
    if let access = insights.access(for: context) {
      AskScreen(context: context, access: access, consents: .live(ai: ai, store: context.stores.main))
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).shadowScreen(.root)
    }
  }
}

struct AskScreen: View {
  @State private var model: AskModel
  @State private var generation = 0
  @Environment(AIServices.self) private var ai
  @Environment(\.horizontalSizeClass) private var sizeClass
  private let context: MemoirScreenContext

  init(context: MemoirScreenContext, access: InsightAccess, consents: InsightConsents) {
    self.context = context
    _model = State(initialValue: AskModel(context: context, access: access, consents: consents))
  }

  var body: some View {
    content
      .navigationTitle(Text("Ask", tableName: "Ask"))
      .task(id: generation) { await model.run() }
      .onChange(of: ai.settings) { Task { await model.refreshSetup() } }
      .aiConsentSheet($model.consentPrompt, services: ai, store: context.stores.main) { Task { await model.consentAllowed() } }
  }

  @ViewBuilder
  private var content: some View {
    switch model.board {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).shadowScreen(.root)
    case .failed(let error):
      ShadowContentUnavailable(Text("Your questions couldn’t be read", tableName: "Ask"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Ask")
        }
      }
      .fillingSurface()
      .shadowScreen(.root)
    case .loaded(let board):
      loaded(board)
    }
  }

  private func loaded(_ board: AskBoard) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        Text(
          "Ask one question about your own history and read the answer here. There is no chat, and nothing is read until you say it may be.", tableName: "Ask"
        )
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
        if model.setup == .noProvider { AskProviderCallout(store: context.stores.main) { Task { await model.refreshSetup() } } }
        AskConsentCard(model: model)
        AskComposer(model: model)
        if let notice = model.notice { AskNoticeView(notice: notice) { model.notice = nil } }
        if let active = board.active { AskActiveCard(request: active, model: model) }
        if let spend = model.spend { AskSpendCard(spend: spend) }
        ForEach(board.results, id: \.id) { result in AskResultCard(result: result, request: board.request(for: result)) }
        if !board.requests.isEmpty { AskHistoryCard(requests: board.requests) }
        AskScheduleCard(schedule: board.schedule, model: model)
        AskGuidance()
      }
      .padding(sizeClass == .compact ? Spacing.space4 : Spacing.space6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .shadowScreen(.root)
  }
}

struct AskProviderCallout: View {
  let store: VaultStore
  let recheck: () -> Void

  var body: some View {
    ShadowCallout(
      Text("Connect an AI provider first", tableName: "Ask"),
      message: Text("Memoir answers with your own Anthropic or OpenRouter key. Add one in AI settings; nothing is sent until you allow it.", tableName: "Ask"),
      intent: .info, systemImage: "key"
    ) {
      ShadowFlowLayout(spacing: Spacing.space3) {
        AISettingsButton(store: store) { _ in EmptyView() }
        Button(action: recheck) { Text("Check Again", tableName: "Ask") }
        TryDemoButton()
      }
    }
  }
}

struct AskConsentCard: View {
  let model: AskModel

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Each kind of data is a separate decision, withdrawable on its own. Withdrawing one leaves it out of every later question.", tableName: "Ask")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
        ForEach(AskConsentKind.allCases, id: \.self) { kind in
          Toggle(isOn: binding(kind)) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
              kind.title.shadowFont(.body)
              kind.detail.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
            }
          }
          .disabled(model.setup == .checking || model.setup == .noProvider)
        }
      }
    } header: {
      AskCardHeader(Text("What Memoir may send", tableName: "Ask"))
    }
  }

  private func binding(_ kind: AskConsentKind) -> Binding<Bool> {
    Binding(
      get: { model.setup.granted.contains(kind) },
      set: { allowed in Task { allowed ? await model.requestConsent(kind) : await model.withdraw(kind) } })
  }
}

extension AskConsentKind {
  var title: Text {
    switch self {
    case .call: Text("Your quests, progress and logs", tableName: "Ask")
    case .journal: Text("Journal reflections and reasons", tableName: "Ask")
    case .health: Text("Health data — a separate decision", tableName: "Ask")
    }
  }

  var detail: Text {
    switch self {
    case .call: Text("Quests and their history, your hero’s progress, money, meals, side quests and general metrics. Needed for any answer.", tableName: "Ask")
    case .journal: Text("The text you write when you reflect, and the reason you attach to a miss. Off by default.", tableName: "Ask")
    case .health:
      Text("Weight, sleep, heart rate, steps and workouts. Off by default and independent of the others.", tableName: "Ask")
    }
  }
}

struct AskComposer: View {
  @Bindable var model: AskModel

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ShadowTextEditor(
          text: $model.question,
          placeholder: Text("Why do Thursdays keep failing, and what would you change about next week?", tableName: "Ask"),
          limit: InsightQuestion.maximumLength, minHeight: 96
        ) { _ in
          Text("\(model.questionLength) of \(InsightQuestion.maximumLength)", tableName: "Ask")
        }
        .disabled(model.isSubmitting)
        .accessibilityLabel(Text("Your question", tableName: "Ask"))
        HStack(spacing: Spacing.space3) {
          Button {
            Task { await model.submit() }
          } label: {
            if model.isSubmitting { ProgressView() } else { Text("Ask", tableName: "Ask") }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!model.canSubmit)
          Button {
            model.question = ""
          } label: {
            Text("Clear", tableName: "Ask")
          }
          .disabled(model.isSubmitting || model.question.isEmpty)
        }
        Text("What Memoir may read is decided by your consents, not by this question.", tableName: "Ask")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    } header: {
      AskCardHeader(Text("Ask a question", tableName: "Ask"))
    }
  }
}

struct AskNoticeView: View {
  let notice: AskNotice
  let dismiss: () -> Void

  var body: some View {
    switch notice {
    case .queued:
      ShadowCallout(Text("Asked. The answer will be here when it’s ready.", tableName: "Ask"), intent: .success, dismiss: dismissal) { EmptyView() }
    case .alreadyRunning:
      ShadowCallout(Text("That question is already being answered.", tableName: "Ask"), intent: .info, dismiss: dismissal) { EmptyView() }
    case .cancelled:
      ShadowCallout(Text("That question was cancelled.", tableName: "Ask"), intent: .neutral, dismiss: dismissal) { EmptyView() }
    case .waitingForSpend(let decision):
      ShadowCallout(AskSpendCard.capText(decision), intent: .warning, dismiss: dismissal) { EmptyView() }
    case .failure(let error):
      ShadowCallout(Text(verbatim: error.headline), message: error.detail.map { Text(verbatim: $0) }, intent: .danger, dismiss: dismissal) { EmptyView() }
    }
  }

  private var dismissal: ShadowCalloutDismiss { ShadowCalloutDismiss(Text("Dismiss", tableName: "Ask"), action: dismiss) }
}

struct AskActiveCard: View {
  let request: InsightRequest
  let model: AskModel

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HStack(spacing: Spacing.space2) {
          ShadowBadge(AskCopy.label(request.status), intent: AskCopy.intent(request.status))
          if request.status == .running { ProgressView().controlSize(.small) }
        }
        AskCopy.title(request).shadowFont(.headline)
        AskCopy.body(request.status).foregroundStyle(ShadowColor.textSecondary)
        if case .failed(let code) = request.status {
          Text(verbatim: AskCopy.failure(code: code).headline).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        actions
      }
    }
  }

  @ViewBuilder
  private var actions: some View {
    let busy = model.acting.contains(request.job)
    switch request.status {
    case .running:
      cancel.disabled(busy)
    case .queued:
      HStack(spacing: Spacing.space3) {
        askAgain.disabled(busy)
        cancel.disabled(busy)
      }
    case .failed, .cancelled:
      askAgain.disabled(busy)
    case .succeeded:
      EmptyView()
    }
  }

  private var cancel: some View {
    Button(role: .destructive) {
      Task { await model.cancel(request) }
    } label: {
      Text("Cancel the Request", tableName: "Ask")
    }
  }

  /// A queued request whose attempt ran on a device that went away starts here once its lease has lapsed.
  private var askAgain: some View {
    Button {
      Task { await model.retry(request) }
    } label: {
      Text("Ask It Again", tableName: "Ask")
    }
    .buttonStyle(.borderedProminent)
  }
}

struct AskSpendCard: View {
  let spend: AskSpend

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        row(Text("Today", tableName: "Ask"), spent: spend.summary.today, limit: spend.limits.daily)
        row(Text("This month", tableName: "Ask"), spent: spend.summary.month, limit: spend.limits.monthly)
        if spend.summary.pendingCalls > 0 {
          Text("Calls still waiting for their price: \(spend.summary.pendingCalls)", tableName: "Ask")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        if spend.decision != .allowed { Self.capText(spend.decision).shadowFont(.footnote).foregroundStyle(ShadowColor.warningText) }
      }
    } header: {
      AskCardHeader(Text("AI spend", tableName: "Ask"))
    }
  }

  private func row(_ title: Text, spent: Cost, limit: Cost?) -> some View {
    LabeledContent {
      if let limit {
        Text("\(AskCopy.money(spent)) of \(AskCopy.money(limit))", tableName: "Ask")
      } else {
        Text(verbatim: AskCopy.money(spent))
      }
    } label: {
      title
    }
  }

  static func capText(_ decision: SpendDecision) -> Text {
    switch decision {
    case .allowed: Text(verbatim: "")
    case .dailyLimitReached(_, let limit):
      Text("Today’s AI spend limit of \(AskCopy.money(limit)) is reached. Questions wait until tomorrow or until you raise it in AI settings.", tableName: "Ask")
    case .monthlyLimitReached(_, let limit):
      Text("This month’s AI spend limit of \(AskCopy.money(limit)) is reached. Questions wait until next month or until you raise it in AI settings.", tableName: "Ask")
    }
  }
}

struct AskResultCard: View {
  let result: InsightResultEntry
  let request: InsightRequest?

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text(meta).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        finding(Text("Answer", tableName: "Ask"), result.answer)
        ForEach(Array(result.patterns.enumerated()), id: \.offset) { index, pattern in
          finding(Text("Pattern \(index + 1)", tableName: "Ask"), pattern)
        }
        if let note = result.limitationNote, !note.isEmpty {
          finding(Text("What this answer could not see", tableName: "Ask"), note)
        }
        if !result.suggestions.isEmpty { suggestions }
      }
    } header: {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        (request.map(AskCopy.title) ?? Text(verbatim: result.question)).shadowFont(.headline)
      }
    }
  }

  private var meta: AttributedString {
    let ready = Date(timeIntervalSince1970: Double(result.createdMillis) / 1000).formatted(date: .abbreviated, time: .shortened)
    guard let cost = request?.cost else { return AttributedString(String(localized: "Ready \(ready)", table: "Ask")) }
    let price =
      cost.pendingCalls > 0
      ? String(localized: "\(AskCopy.money(cost.cost)) so far, price still arriving", table: "Ask") : AskCopy.money(cost.cost)
    return AttributedString(String(localized: "Ready \(ready) · cost \(price)", table: "Ask"))
  }

  private func finding(_ heading: Text, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      heading.shadowFont(.subheadline)
      Text(verbatim: body).textSelection(.enabled)
    }
  }

  private var suggestions: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text("Suggestions", tableName: "Ask").shadowFont(.subheadline)
      Text("Nothing changes until you edit the quest yourself.", tableName: "Ask").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, suggestion in
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text(verbatim: suggestion.text)
          NavigationLink(value: AskSuggestionLink.route(for: suggestion)) {
            AskSuggestionLink.label(for: suggestion)
          }
        }
      }
    }
  }
}

/// Where the owner takes a suggestion by hand: the quest builder for a change to its fields, a copy of it to split it, its detail to pause it.
enum AskSuggestionLink {
  static func route(for suggestion: InsightSuggestion) -> MemoirRoute {
    switch suggestion.kind {
    case .known(.shiftTime), .known(.adjustDuration), .known(.adjustStrictness), .known(.adjustReminder): .quest(.edit(suggestion.quest))
    case .known(.splitQuest): .quest(.duplicate(suggestion.quest))
    case .known(.pauseQuest), .unknown: .quest(.detail(suggestion.quest))
    }
  }

  static func label(for suggestion: InsightSuggestion) -> Text {
    switch route(for: suggestion) {
    case .quest(.edit): Text("Edit the quest", tableName: "Ask")
    case .quest(.duplicate): Text("Make a copy to split it", tableName: "Ask")
    default: Text("Open the quest", tableName: "Ask")
    }
  }
}

struct AskHistoryCard: View {
  let requests: [InsightRequest]
  @State private var expanded = false
  private static let preview = 5

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        ForEach(expanded ? requests : Array(requests.prefix(Self.preview))) { request in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            ShadowBadge(AskCopy.label(request.status), intent: AskCopy.intent(request.status))
            AskCopy.title(request).lineLimit(2)
            Spacer(minLength: 0)
            if let started = request.startedMillis {
              Text(Date(timeIntervalSince1970: Double(started) / 1000), format: .dateTime.day().month().hour().minute())
                .shadowFont(.footnote)
                .foregroundStyle(ShadowColor.textSecondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
        if requests.count > Self.preview {
          Button {
            expanded.toggle()
          } label: {
            expanded ? Text("Show the latest \(Self.preview)", tableName: "Ask") : Text("Show all \(requests.count)", tableName: "Ask")
          }
        }
      }
    } header: {
      AskCardHeader(Text("Result history", tableName: "Ask"))
    }
  }
}

struct AskScheduleCard: View {
  let schedule: InsightScheduleRecord?
  let model: AskModel
  @State private var question = ""
  @State private var time = Date()
  @State private var editing = false

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let schedule, schedule.active, !editing {
          Text(verbatim: schedule.question)
          Text("Asked every night at \(Self.timeText(schedule.minuteOfDay)), the next time Memoir is open after it.", tableName: "Ask")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
          HStack(spacing: Spacing.space3) {
            Button {
              start(from: schedule)
            } label: {
              Text("Change", tableName: "Ask")
            }
            Button(role: .destructive) {
              Task { await model.clearSchedule() }
            } label: {
              Text("Turn Off", tableName: "Ask")
            }
          }
        } else if editing {
          TextField(text: $question, axis: .vertical) { Text("The question to ask every night", tableName: "Ask") }
          DatePicker(selection: $time, displayedComponents: .hourAndMinute) { Text("Time", tableName: "Ask") }
          HStack(spacing: Spacing.space3) {
            Button {
              Task {
                if await model.setSchedule(question: question, minuteOfDay: Self.minute(of: time)) { editing = false }
              }
            } label: {
              Text("Save", tableName: "Ask")
            }
            .disabled(!(1...InsightQuestion.maximumLength).contains(question.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count))
            Button {
              editing = false
            } label: {
              Text("Cancel", tableName: "Ask")
            }
          }
        } else {
          Text("Ask one standing question every night, answered the next time Memoir is open on any of your devices.", tableName: "Ask")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
          Button {
            start(from: schedule)
          } label: {
            Text("Set a Nightly Question", tableName: "Ask")
          }
        }
      }
    } header: {
      AskCardHeader(Text("Nightly summary", tableName: "Ask"))
    }
  }

  private func start(from schedule: InsightScheduleRecord?) {
    question = schedule?.question ?? ""
    time = Self.date(minute: schedule?.minuteOfDay ?? InsightScheduleRecord.defaultMinuteOfDay)
    editing = true
  }

  static func minute(of date: Date) -> Int {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
  }

  static func date(minute: Int) -> Date {
    Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
  }

  static func timeText(_ minute: Int) -> String {
    date(minute: minute).formatted(date: .omitted, time: .shortened)
  }
}

struct AskCardHeader: View {
  let title: Text

  init(_ title: Text) {
    self.title = title
  }

  var body: some View {
    title.shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
  }
}

struct AskGuidance: View {
  var body: some View {
    ShadowCard {
      Text(
        "Answers read patterns in your logs and nothing more. They are not a therapist or a crisis service. If something heavier is going on, please reach a person — a local helpline or someone you trust — rather than this screen.",
        tableName: "Ask"
      )
      .shadowFont(.footnote)
    } header: {
      AskCardHeader(Text("If you are struggling", tableName: "Ask"))
    }
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    let ai = AIServices.memoir(defaults: UserDefaults(suiteName: "memoir.ask.preview") ?? .standard)
    let access = MemoirInsights.access(stores: context.stores, clock: context.clock, ai: ai, trustedClock: nil)
    NavigationStack { AskScreen(context: context, access: access, consents: .live(ai: ai, store: context.stores.main)) }
      .environment(ai)
      .shadowTheme()
  }
}
