import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/quests/quest-detail-screen.tsx`: a quest's standing, history, rules and load, with edit, duplicate and delete.
struct QuestDetailView: View {
  @State private var model: QuestDetailModel
  @Environment(\.dismiss) private var dismiss
  @Environment(SyncRuntimes.self) private var sync: SyncRuntimes?

  init(questID: UUID, context: MemoirScreenContext) {
    _model = State(initialValue: QuestDetailModel(questID: questID, context: context))
  }

  var body: some View {
    @Bindable var model = model
    content
      .navigationTitle(title)
      .shadowScreen(.pushed)
      .task { await model.observe() }
      .confirmationDialog(Text("Delete this quest?", tableName: "Quests"), isPresented: $model.isConfirmingDelete, titleVisibility: .visible) {
        Button(role: .destructive) {
          Task { await model.delete() }
        } label: {
          Text("Delete quest", tableName: "Quests")
        }
        Button(role: .cancel) {
          model.cancelDelete()
        } label: {
          Text("Cancel", tableName: "Quests")
        }
      } message: {
        Text("It moves to Inactive. Its XP, streak record and entries stay in History.", tableName: "Quests")
      }
  }

  private var title: Text {
    guard let quest = model.detail.state.value?.summary?.quest else { return Text("Quest details", tableName: "Quests") }
    return Text(verbatim: QuestsCopy.name(quest.name))
  }

  @ViewBuilder
  private var content: some View {
    switch model.detail.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("This quest couldn’t be loaded", tableName: "Quests"), kind: .error, message: error.text)
    case .loaded(let detail):
      if let summary = detail.summary {
        page(detail, summary: summary)
      } else {
        ShadowContentUnavailable(
          Text("This quest isn’t here", tableName: "Quests"), kind: .noResults,
          message: Text("It may have been removed, or the link is wrong.", tableName: "Quests")
        ) {
          Button {
            dismiss()
          } label: {
            Text("Back to Quests", tableName: "Quests")
          }.buttonStyle(.shadowBordered)
        }
      }
    }
  }

  private func page(_ detail: QuestDetail, summary: QuestSummary) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let failure = model.failure {
          ShadowCallout(Text("Quest not deleted", tableName: "Quests"), message: failure.text, intent: .danger)
        }
        ShadowAdaptiveColumns {
          standing(detail, summary: summary)
          history(detail, summary: summary)
          rules(detail, summary: summary)
          if detail.scheduleEdit == .unavailable(.lockedInTodaysPlan) {
            ShadowCallout(
              Text("Two fields are read-only today", tableName: "Quests"),
              message: Text("Today’s plan is locked, so schedule and strictness can’t change until tomorrow.", tableName: "Quests"), intent: .info)
          }
          if let load = detail.load { loadCard(load, quest: summary.quest) }
          totals(detail.totals)
        }
      }
      .padding(Spacing.space4)
    }
  }

  private func standing(_ detail: QuestDetail, summary: QuestSummary) -> some View {
    let quest = summary.quest
    let streak = summary.streak
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text(verbatim: QuestsCopy.name(quest.name)).shadowFont(.title2).foregroundStyle(ShadowColor.textPrimary)
        ShadowFlowLayout {
          ShadowTag(Text(verbatim: QuestsCopy.stat(quest.statAffinity)))
          ShadowBadge(Text(verbatim: QuestsCopy.strictness(quest.strictness)))
          ShadowBadge(Text(verbatim: QuestsCopy.schedule(quest)))
          if streak.shields > 0 { ShadowBadge(Text(verbatim: QuestsCopy.shields(streak.shields))) }
          if !quest.isActive { ShadowBadge(Text("Kept as history", tableName: "Quests"), intent: .neutral, systemImage: "archivebox") }
          if summary.lockedToday { ShadowBadge(Text("Locked plan", tableName: "Quests"), intent: .info, systemImage: "lock") }
        }
        if let notes = quest.notes, !notes.isEmpty {
          Text(verbatim: notes).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
        }
        if let today = detail.today { todayLine(today) }
        ShadowStatisticGrid {
          ShadowStatistic(Text("Current streak", tableName: "Quests"), value: Text(verbatim: QuestsCopy.streak(streak.currentDays, unit: streak.unit)))
          if let ratio = summary.adherence.ratio {
            ShadowStatistic(Text("Kept, 30 days", tableName: "Quests"), value: Text(verbatim: QuestsCopy.percent(ratio)))
          } else {
            ShadowStatistic(Text("Kept, 30 days", tableName: "Quests"), value: Text(verbatim: "—"), caption: Text("Not enough history yet", tableName: "Quests"))
          }
          ShadowStatistic(Text("XP from this quest", tableName: "Quests"), value: Text(summary.xpEarned, format: .number))
          ShadowStatistic(Text("Longest streak", tableName: "Quests"), value: Text(verbatim: QuestsCopy.streak(streak.longestDays, unit: streak.unit)))
        }
      }
    }
  }

  private func todayLine(_ occurrence: BoardOccurrence) -> some View {
    let time = QuestsCopy.time(occurrence.plannedMinute) ?? String(localized: "all day", table: "Quests")
    return HStack(spacing: Spacing.space2) {
      Image(systemName: "sun.max").foregroundStyle(ShadowColor.accent)
      Text("Today · \(time)", tableName: "Quests").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
      ShadowBadge(Text(verbatim: QuestsCopy.status(occurrence.status)), intent: intent(of: occurrence.effectiveState))
    }
    .accessibilityElement(children: .combine)
  }

  private func history(_ detail: QuestDetail, summary: QuestSummary) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HStack {
          Text("Last 30 days", tableName: "Quests").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          Spacer()
          Group {
            if let ratio = summary.adherence.ratio {
              Text("\(QuestsCopy.percent(ratio)) kept", tableName: "Quests")
            } else {
              Text("Not enough history yet", tableName: "Quests")
            }
          }
          .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        if summary.adherence.ratio == nil {
          Text("Complete or skip this quest a few times and its 30-day chart fills in.", tableName: "Quests")
            .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        ForEach(detail.history) { entry in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            Text(verbatim: QuestsCopy.shortDate(entry.date)).shadowFont(.monoBody).foregroundStyle(ShadowColor.textSecondary)
            ShadowBadge(Text(verbatim: QuestsCopy.state(entry.log.state)), intent: intent(of: entry.log.state))
            note(entry.log).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func note(_ log: OccurrenceLog) -> Text {
    if let tag = log.reasonTag { return Text("Reason: \(QuestsCopy.reason(tag))", tableName: "Quests") }
    return Text("Recorded as \(QuestsCopy.state(log.state).localizedLowercase)", tableName: "Quests")
  }

  private func rules(_ detail: QuestDetail, summary: QuestSummary) -> some View {
    let quest = summary.quest
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Rules on this quest", tableName: "Quests").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        ShadowLabeledContent(title: Text("Strictness", tableName: "Quests")) { Text(verbatim: QuestsCopy.strictnessRule(quest.strictness)) }
        ShadowLabeledContent(title: Text("Reschedules", tableName: "Quests")) { Text(verbatim: QuestsCopy.reschedules(summary.reschedule)) }
        ShadowLabeledContent(title: Text("Shields", tableName: "Quests")) {
          Text("\(summary.streak.shields) held · a miss, skip or postpone spends one to keep the streak", tableName: "Quests")
        }
        ShadowLabeledContent(title: Text("Threshold", tableName: "Quests")) { thresholdText }
        ShadowLabeledContent(title: Text("Editing", tableName: "Quests")) {
          if detail.scheduleEdit == .available {
            Text("Schedule and strictness can change today", tableName: "Quests")
          } else if case .unavailable(let block) = detail.scheduleEdit, block != .lockedInTodaysPlan, let reason = QuestsCopy.block(block) {
            Text(verbatim: reason)
          } else {
            Text("Schedule and strictness are locked today", tableName: "Quests")
          }
        }
        ShadowFlowLayout {
          if quest.isActive {
            NavigationLink(value: MemoirRoute.quest(.edit(quest.id))) { Text("Edit quest", tableName: "Quests") }
              .buttonStyle(.shadowBordered)
              .keyboardShortcut("e", modifiers: .command)
          }
          NavigationLink(value: MemoirRoute.quest(.duplicate(quest.id))) { Text("Duplicate as a new quest", tableName: "Quests") }
            .buttonStyle(.shadowBordered)
          if quest.isActive {
            Button(role: .destructive) {
              model.requestDelete()
            } label: {
              Text("Delete quest", tableName: "Quests")
            }
            .buttonStyle(.shadowPlain)
            .disabled(!model.canDelete)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var thresholdText: some View {
    if let threshold = model.threshold.state.value ?? nil {
      Text("\(QuestsCopy.threshold(threshold)) — completion is offered, never automatic", tableName: "Quests")
    } else if QuestThresholdReader.mayLiveElsewhere(isSyncing: sync?.runtime != nil, syncingRoutes: sync?.syncingRoutes ?? []) {
      Text(QuestsCopy.thresholdElsewhere)
    } else {
      Text("None — completion is manual", tableName: "Quests")
    }
  }

  /// `loadSummary` and `loadShare` (`fixture-provider.ts:603-616`).
  private func loadCard(_ load: QuestLoad, quest: QuestSnapshot) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Load contribution", tableName: "Quests").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        Text("About \(QuestsCopy.duration(quest.durationMinutes)) on the days it runs, \(cadence(load, quest: quest)).", tableName: "Quests")
          .shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
        ProgressView(value: load.share.map { Double($0.numerator) / Double($0.denominator) } ?? 0)
          .progressViewStyle(.shadowLinear)
          .accessibilityLabel(Text("Share of your week", tableName: "Quests"))
      }
    }
  }

  private func cadence(_ load: QuestLoad, quest: QuestSnapshot) -> String {
    switch quest.recurrence.frequency {
    case .monthly: String(localized: "once a month", table: "Quests")
    case .yearly: String(localized: "once a year", table: "Quests")
    case .daily, .weekly: String(localized: "\(load.daysPerWeek.floor) days a week", table: "Quests")
    }
  }

  private func totals(_ totals: QuestTotals) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Lifetime", tableName: "Quests").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        ShadowStatisticGrid(minimumWidth: 100) {
          ForEach([QuestLogState.completed, .late, .partial, .skipped, .postponed, .missed], id: \.self) { state in
            ShadowStatistic(Text(verbatim: QuestsCopy.state(state)), value: Text(totals.byState[state] ?? 0, format: .number))
          }
          ShadowStatistic(Text("Coins from this quest", tableName: "Quests"), value: Text(totals.coins, format: .number))
        }
      }
    }
  }

  /// `outcomeTone` (`quest-presenters.ts:62-67`).
  private func intent(of state: QuestLogState?) -> ShadowBadgeIntent {
    switch state {
    case .completed: .success
    case .partial, .recovery, .late: .warning
    case .rescheduled, nil: .info
    case .skipped, .missed, .postponed: .neutral
    }
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      QuestDetailView(questID: UUID(), context: context)
    }
  }
}
