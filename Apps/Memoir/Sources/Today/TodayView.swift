import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Today first (`features/today/index.tsx`): the hero, what needs saying, the day's quests and their actions, and on a wide screen the rail beside them.
struct TodayView: View {
  @State private var model: TodayViewModel
  @State private var game: MoneyGameModel
  @State private var toasts = ShadowToastCenter()
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  init(context: MemoirScreenContext) {
    _model = State(initialValue: TodayViewModel(context: context))
    _game = State(initialValue: MoneyGameModel(context: context))
  }

  /// Today exists only with Quests, so Hero is on: money in the game needs only Money.
  private var showsMoney: Bool { modules?.selection.contains(.money) ?? true }

  var body: some View {
    TodayScreen(model: model, game: showsMoney ? game : nil, toasts: toasts)
      .shadowToastPresenter(toasts)
      .task(id: showsMoney) {
        guard showsMoney else { return }
        await game.run()
      }
  }
}

private struct TodayScreen: View {
  let model: TodayViewModel
  let game: MoneyGameModel?
  let toasts: ShadowToastCenter
  @State private var presentation: QuestActionPresentation?
  @State private var isKeepingRecovery = false
  @State private var generation = 0
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let error):
        ShadowContentUnavailable(Text("Today couldn’t be read", tableName: "Today"), kind: .error, message: error.text) {
          Button {
            generation += 1
          } label: {
            Text("Try Again", tableName: "Today")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded(let snapshot):
        loaded(snapshot)
      }
    }
    .navigationTitle(Text(MemoirDestination.today.title))
    .shadowScreen(.root)
    .task(id: generation) { await model.observe() }
    .sheet(item: $presentation) { presentation in
      QuestActionSheet(host: model, presentation: presentation, dayLabel: dayLabel(for: presentation.occurrence), finished: finished)
    }
    .sheet(isPresented: $isKeepingRecovery) {
      TodayRecoverySheet(model: model) { _ in
        toasts.show(ShadowToast(LocalizedStringResource("Recovery quest kept", table: "Today"), intent: .success))
      }
    }
  }

  private func loaded(_ snapshot: TodaySnapshot) -> some View {
    ScrollView {
      TimelineView(.everyMinute) { _ in
        if sizeClass == .compact {
          main(snapshot)
        } else {
          HStack(alignment: .top, spacing: Spacing.space5) {
            main(snapshot).frame(maxWidth: ShadowMetrics.readableWidth)
            TodayRail(snapshot: snapshot).frame(width: ShadowMetrics.inspector)
          }
          .frame(maxWidth: .infinity)
        }
      }
      .padding(Spacing.space4)
    }
    .background(ShadowColor.surfaceApp)
  }

  private func main(_ snapshot: TodaySnapshot) -> some View {
    let board = snapshot.board
    let minutesLeft = model.minutesUntilSleep()
    return VStack(alignment: .leading, spacing: Spacing.space4) {
      Text(verbatim: TodayFormat.dayName(snapshot.today.date)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      ForEach(snapshot.notices, id: \.self) { TodayNoticeView(notice: $0) }
      TodayHeroCard(
        hero: snapshot.hero, summary: board.summary, comingBack: board.comingBack, showsCrown: snapshot.hasActiveQuests, money: game?.snapshot)
      if let game { TodayMoneyCards(game: game) }
      if let reason = board.comingBack, reason != .comeback, !ComingBackDismissal(defaults: model.context.defaults).isDismissed(on: snapshot.today.date) {
        TodayComingBack(reason: reason)
      }
      if let recovery = board.recovery {
        TodayRecoveryCard(offer: recovery, zone: model.timeZone(), isBusy: model.actions.isCompletingRecovery) { isKeepingRecovery = true }
      }
      switch snapshot.content {
      case .quests:
        TodayQuestList(
          board: board, wakeNote: minutesLeft.map(Self.wakeNote), actions: model.actions, nowMillis: model.nowMillis, complete: complete,
          openActions: { presentation = QuestActionPresentation(occurrence: $0.id, step: .menu) })
      case .nothingDue(let next):
        TodayNothingDue(next: next, today: snapshot.today.date)
      case .firstDay:
        TodayFirstDay()
      }
      if let end = snapshot.dayEnd(minutesUntilSleep: minutesLeft) {
        TodayDayEndCard(end: end)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// `wakeWindowNote` (`fixture-provider.ts:279-283`).
  private static func wakeNote(_ minutes: Int) -> String {
    guard minutes > 0 else { return String(localized: "the wake window has closed", table: "Today") }
    return String(localized: "about \(TodayFormat.duration(minutes: minutes)) of wake window left", table: "Today")
  }

  private func dayLabel(for occurrence: Occurrence) -> String {
    TodayFormat.relativeDay(occurrence.date, from: model.snapshot?.today.date ?? occurrence.date)
  }

  private func complete(_ occurrence: BoardOccurrence) {
    let request = QuestActionRequest.complete(occurrence.id)
    Task {
      let outcome = await model.perform(request)
      TodayToasts.report(outcome, of: request, before: occurrence, model: model, toasts: toasts)
    }
  }

  private func finished(_ completion: QuestActionCompletion) {
    TodayToasts.report(.done(offersUndo: completion.offersUndo), of: completion.request, before: completion.before, model: model, toasts: toasts)
  }
}

/// The reference's toasts after an action (`command-feedback.ts`), with Undo after a bare skip or postpone.
@MainActor
enum TodayToasts {
  static func report(_ outcome: QuestActionOutcome, of request: QuestActionRequest, before: BoardOccurrence, model: TodayViewModel, toasts: ShadowToastCenter) {
    let name = QuestActionCopy.name(before.quest)
    switch outcome {
    case .done(let offersUndo):
      let message = QuestActionCopy.success(request, for: before)
      let undo =
        offersUndo
        ? ShadowToastButton(LocalizedStringResource("Undo", table: "Today")) {
          let undo = QuestActionRequest.undo(request.occurrence)
          Task { report(await model.perform(undo), of: undo, before: before, model: model, toasts: toasts) }
        } : nil
      toasts.show(ShadowToast(LocalizedStringResource("\(message)", table: "Today"), intent: .success, action: undo))
    case .failed(let error):
      let message = QuestActionCopy.failure(request.kind, name: name, message: error.headline)
      toasts.show(ShadowToast(LocalizedStringResource("\(message)", table: "Today"), intent: .danger))
    case .unavailable(let reason):
      guard let message = QuestActionCopy.unavailable(reason, for: request.kind) else { return }
      toasts.show(ShadowToast(LocalizedStringResource("\(message)", table: "Today"), intent: .warning))
    case .cancelled:
      return
    }
  }
}

#if DEBUG
  #Preview("Today") {
    if let context = try? MemoirScreenContext.inMemory() {
      NavigationStack { TodayView(context: context) }
        .task { await TodayPreviewData.seed(context) }
        .shadowTheme()
    }
  }
#endif
