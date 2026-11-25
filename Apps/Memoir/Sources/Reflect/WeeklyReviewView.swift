import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// `features/review/index.tsx`: a restrained look back at last week in five short steps, every prompt optional and its answers kept on this device.
struct WeeklyReviewView: View {
  @State private var model: WeeklyReviewModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: WeeklyReviewModel(context: context))
  }

  var body: some View {
    WeeklyReviewScreen(model: model)
  }
}

private struct WeeklyReviewScreen: View {
  let model: WeeklyReviewModel
  @State private var generation = 0
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  private var moduleSelection: ModuleSelection { modules?.selection ?? .all }

  private var introduction: Text {
    model.steps.count == ReviewStep.allCases.count
      ? Text("A restrained look back at the week, in five short steps. Every prompt in it is optional.", tableName: "Reflect")
      : Text("A restrained look back at the week, in \(model.steps.count) short steps. Every prompt in it is optional.", tableName: "Reflect")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        introduction
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        content
      }
      .padding(Spacing.space4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(ShadowColor.surfaceApp)
    .navigationTitle(Text(MemoirDestination.weeklyReview.title))
    .shadowScreen(.root)
    .onChange(of: moduleSelection, initial: true) { model.apply(moduleSelection) }
    .task { await model.followToday() }
    .task { await model.observeLookups() }
    .task(id: model.modules.contains(.money)) { await model.observeSavings() }
    .task(id: ObservationKey(today: model.day.day?.today, generation: generation, readsBody: model.modules.contains(.body))) { await model.observe() }
  }

  @ViewBuilder
  private var content: some View {
    if let failure = model.day.failure {
      ShadowContentUnavailable(Text("The review couldn’t be loaded", tableName: "Reflect"), kind: .error, message: failure.text)
    } else {
      switch model.review.state {
      case .loading:
        ProgressView().frame(maxWidth: .infinity)
      case .failed(let error):
        ShadowContentUnavailable(Text("Couldn’t load this right now", tableName: "Reflect"), kind: .error, message: error.text) {
          Button {
            generation += 1
          } label: {
            Text("Try again", tableName: "Reflect")
          }
          .buttonStyle(.shadowBordered)
        }
      case .loaded(let review):
        if sizeClass == .compact {
          main(review)
          aside(review)
        } else {
          HStack(alignment: .top, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space4) { main(review) }.frame(maxWidth: ShadowMetrics.readableWidth)
            VStack(alignment: .leading, spacing: Spacing.space4) { aside(review) }.frame(width: ShadowMetrics.inspector)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func main(_ review: WeeklyReview) -> some View {
    ReviewStepBar(model: model, review: review)
    if let failure = model.failure {
      ShadowCallout(Text(verbatim: failure.headline), message: failure.detail.map { Text(verbatim: $0) }, intent: .danger)
    }
    switch model.step {
    case .kept: ReviewKeptStep(review: review)
    case .money: ReviewMoneyStep(review: review, lookups: model.lookups.state.value, savings: model.savings.state.value ?? nil)
    case .body: ReviewBodyStep(review: review, bodyClasses: model.bodyClasses)
    case .reflect: ReviewReflectStep(model: model)
    case .done: ReviewDoneStep(model: model, review: review)
    }
  }

  @ViewBuilder
  private func aside(_ review: WeeklyReview) -> some View {
    InsightCard(title: Text("Week at a glance", tableName: "Reflect")) {
      ForEach(WeeklyReviewPresentation.glance(review, modules: model.modules), id: \.self) { line in
        Text(verbatim: line).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      }
    }
    if modules?.shows(.destination(.planningBoard)) ?? true {
      InsightCard(title: Text("Carried into planning", tableName: "Reflect")) {
        Text("Anything you decide here reaches the Planning Board as a suggestion. The board never rewrites itself.", tableName: "Reflect")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        NavigationLink(value: MemoirRoute.destination(.planningBoard)) { Text("Open the board", tableName: "Reflect") }
          .buttonStyle(.shadowBordered)
      }
    }
  }

  private struct ObservationKey: Hashable {
    let today: LocalDate?
    let generation: Int
    let readsBody: Bool
  }
}

private struct ReviewStepBar: View {
  let model: WeeklyReviewModel
  let review: WeeklyReview
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  private var index: Int { model.steps.firstIndex(of: model.step) ?? 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Spacing.space3) {
          heading
          Spacer(minLength: Spacing.space2)
          actions
        }
        VStack(alignment: .leading, spacing: Spacing.space3) {
          heading
          actions
        }
      }
      ShadowSteps(current: index, titles: model.steps.map { Text(verbatim: WeeklyReviewPresentation.title($0)) }) { position in
        Text("Step \(position.number) of \(position.count)", tableName: "Reflect")
      }
    }
    .shadowCard()
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(verbatim: WeeklyReviewPresentation.weekLabel(review))
        .shadowFont(.headline)
        .foregroundStyle(ShadowColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Group {
        if model.step == .done {
          model.isComplete ? Text("Completed", tableName: "Reflect") : Text("Not finished yet", tableName: "Reflect")
        } else {
          Text("Step \(index + 1) of \(model.steps.count) · about four minutes", tableName: "Reflect")
        }
      }
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack(spacing: Spacing.space2) {
      Button {
        Task { await model.back() }
      } label: {
        Text("Back", tableName: "Reflect")
      }
      .buttonStyle(.shadowBordered)
      .disabled(index == 0)
      if model.step == .done {
        if model.isComplete {
          if modules?.shows(.destination(.planningBoard)) ?? true {
            NavigationLink(value: MemoirRoute.destination(.planningBoard)) { Text("Plan next week", tableName: "Reflect") }
              .buttonStyle(.shadowFilled)
          }
        } else {
          Button {
            Task { await model.show(.reflect) }
          } label: {
            Text("Back to reflection", tableName: "Reflect")
          }
          .buttonStyle(.shadowFilled)
        }
      } else {
        Button {
          Task { await model.advance() }
        } label: {
          model.step == .reflect && !model.isComplete ? Text("Finish the review", tableName: "Reflect") : Text("Continue", tableName: "Reflect")
        }
        .buttonStyle(.shadowFilled)
        .shadowLoading(model.isFinishing)
        .disabled(model.isFinishing)
        .keyboardShortcut(.return, modifiers: .command)
      }
    }
  }
}

private struct ReviewKeptStep: View {
  let review: WeeklyReview

  var body: some View {
    InsightCard(title: Text("What you kept", tableName: "Reflect")) {
      Text(verbatim: WeeklyReviewPresentation.keptHeadline(review.kept)).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
      ShadowFlowLayout(spacing: Spacing.space3, lineSpacing: Spacing.space1) {
        ForEach([ReviewDayOutcome.kept, .partial, .missed, .none], id: \.self) { outcome in
          HStack(spacing: Spacing.space1) {
            ReviewDaySwatch(outcome: outcome).frame(width: Spacing.space3, height: Spacing.space3)
            Text(verbatim: WeeklyReviewPresentation.outcome(outcome)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
      .accessibilityHidden(true)
      ForEach(review.kept.quests, id: \.quest) { row in
        VStack(alignment: .leading, spacing: Spacing.space1) {
          HStack(alignment: .firstTextBaseline) {
            Text(verbatim: ReflectCopy.questName(row.name)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
            Spacer(minLength: Spacing.space2)
            Text(verbatim: WeeklyReviewPresentation.result(row)).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
          }
          HStack(spacing: Spacing.space1) {
            ForEach(Array(row.days.enumerated()), id: \.offset) { _, outcome in
              ReviewDaySwatch(outcome: outcome).frame(height: Spacing.space3)
            }
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          Text("\(ReflectCopy.questName(row.name)): \(WeeklyReviewPresentation.result(row)) across the week", tableName: "Reflect"))
      }
      Text(verbatim: WeeklyReviewPresentation.keptPattern(review.kept)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

private struct ReviewDaySwatch: View {
  let outcome: ReviewDayOutcome

  var body: some View {
    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
      .fill(fill)
      .overlay {
        if outcome == .none {
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(ShadowColor.borderDefault, lineWidth: 1)
        }
      }
  }

  private var fill: Color {
    switch outcome {
    case .kept: ShadowColor.successSolid
    case .partial: ShadowColor.warningSolid
    case .missed: ShadowColor.dangerSolid
    case .none: ShadowColor.fillTrack
    }
  }
}

private struct ReviewFacts: View {
  let facts: [ReviewFact]

  var body: some View {
    ShadowStatisticGrid {
      ForEach(facts) { fact in
        ShadowStatistic(Text(verbatim: fact.label), value: Text(verbatim: fact.value), caption: Text(verbatim: fact.comparison))
      }
    }
  }
}

private struct ReviewMoneyStep: View {
  let review: WeeklyReview
  let lookups: ReflectLookups?
  let savings: SavingsSnapshot?
  @Environment(\.locale) private var locale

  var body: some View {
    InsightCard(title: Text("Money", tableName: "Reflect")) {
      Text(verbatim: WeeklyReviewPresentation.moneyHeadline(review.money)).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
      ReviewFacts(facts: WeeklyReviewPresentation.moneyFacts(review.money, lookups: lookups))
      if let note = WeeklyReviewPresentation.moneyNote(review.money, lookups: lookups) {
        Text(verbatim: note).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      }
      if let pending = review.money.flatMap({ ReflectCopy.pending($0.spent.pending) }) {
        Text(verbatim: pending).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
    if let goal = WeeklyReviewPresentation.goal(savings, locale: locale) {
      ReviewGoalCard(goal: goal)
    }
  }
}

private struct ReviewGoalCard: View {
  let goal: ReviewGoal

  var body: some View {
    InsightCard(title: Text("Savings goal", tableName: "Reflect")) {
      HStack(spacing: Spacing.space3) {
        GoalRing(symbol: goal.symbol, thousandths: goal.thousandths)
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text(verbatim: goal.name).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: goal.saved).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: goal.accessibilityLabel))
      if let forecast = goal.forecast {
        Text(verbatim: forecast).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).fixedSize(horizontal: false, vertical: true)
      }
      Text(verbatim: goal.pace).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      if let live = goal.liveMonth {
        Text(verbatim: live).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

private struct ReviewBodyStep: View {
  let review: WeeklyReview
  let bodyClasses: Set<SyncClass>

  var body: some View {
    InsightCard(title: Text("Body", tableName: "Reflect")) {
      Text(verbatim: WeeklyReviewPresentation.bodyHeadline(review.body)).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
      ReviewFacts(facts: WeeklyReviewPresentation.bodyFacts(review.body))
      if let gap = WeeklyReviewPresentation.bodyGap(review.body) {
        ShadowCallout(Text(verbatim: gap.title), message: Text(verbatim: gap.message), intent: .info)
      }
      ForEach(ReflectCopy.missingClasses(bodyClasses), id: \.self) { note in
        Text(verbatim: note).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

private struct ReviewReflectStep: View {
  @Bindable var model: WeeklyReviewModel
  @FocusState private var focused: ReviewPrompt?

  var body: some View {
    InsightCard(title: Text("Your reflection", tableName: "Reflect")) {
      Text("Three prompts, all optional. What you write stays on this device, alongside the rest of this week’s review.", tableName: "Reflect")
        .shadowFont(.body)
        .foregroundStyle(ShadowColor.textPrimary)
      ForEach(ReviewPrompt.allCases, id: \.self) { prompt in
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text(verbatim: WeeklyReviewPresentation.question(prompt)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
          ShadowTextEditor(
            text: Binding(
              get: { model.drafts[prompt] ?? "" },
              set: {
                model.drafts[prompt] = $0
                model.edited(prompt)
              }),
            placeholder: Text(verbatim: WeeklyReviewPresentation.placeholder(prompt)), minHeight: 56, maxHeight: 200
          ) { _ in
            status(prompt)
          }
          .focused($focused, equals: prompt)
          .accessibilityLabel(Text(verbatim: WeeklyReviewPresentation.question(prompt)))
        }
      }
    }
    .onChange(of: focused) { previous, _ in
      guard let previous else { return }
      Task { await model.save(previous) }
    }
    .onDisappear { Task { await model.saveAll() } }
  }

  private func status(_ prompt: ReviewPrompt) -> Text {
    switch model.status[prompt] ?? .idle {
    case .idle: Text(verbatim: "")
    case .saving: Text("Saving…", tableName: "Reflect")
    case .saved: Text("Saved", tableName: "Reflect")
    }
  }
}

private struct ReviewDoneStep: View {
  let model: WeeklyReviewModel
  let review: WeeklyReview

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      if model.isComplete {
        ShadowCallout(
          Text(verbatim: WeeklyReviewPresentation.completionTitle(review)),
          message: Text("Kept on this device. It stays here, but does not follow you to another device.", tableName: "Reflect"), intent: .success)
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ForEach(WeeklyReviewPresentation.summary(review, modules: model.modules), id: \.self) { line in
            Text(verbatim: line).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
          }
        }
        .accessibilityElement(children: .combine)
      } else {
        ShadowCallout(
          Text("Not finished yet", tableName: "Reflect"), message: Text("The week closes once you finish the reflection step.", tableName: "Reflect"),
          intent: .info)
      }
    }
    .shadowCard()
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      WeeklyReviewView(context: context)
    }
  }
}
