import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/quick-logs/side-quests-screen.tsx`: log what you did, find it again, and see the month's XP from it.
struct SideQuestsView: View {
  @State private var model: SideQuestsModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: SideQuestsModel(context: context))
  }

  var body: some View {
    LogLoadable(state: model.overview.state, failureTitle: Text("Side quests couldn’t be loaded", tableName: "Log")) { overview in
      ScrollView {
        ShadowAdaptiveColumns {
          VStack(alignment: .leading, spacing: Spacing.space4) {
            form(overview)
            list(overview)
          }
          month(overview)
        }
        .padding(Spacing.space4)
      }
    }
    .navigationTitle(Text("Side quests", tableName: "Log"))
    .shadowScreen(.pushed)
    .task { await model.observe() }
  }

  private func form(_ overview: SideQuestsOverview) -> some View {
    @Bindable var model = model
    let remaining = overview.remainingRewardsToday
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Log a side quest", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        Text("Something you did that no quest asked for. It earns XP once, has no schedule and no streak to protect.", tableName: "Log")
          .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        TextField(text: $model.name, prompt: Text("Fixed the bike light", tableName: "Log")) { Text("What you did", tableName: "Log") }
          .shadowField()
          .onSubmit { Task { await model.save() } }
        HStack(spacing: Spacing.space3) {
          Picker(selection: $model.stat) {
            ForEach(SideQuestsModel.statOrder, id: \.self) { stat in Text(verbatim: LogFormat.stat(stat)).tag(stat) }
          } label: {
            Text("Stat", tableName: "Log")
          }
          .fixedSize()
          Button {
            Task { await model.save() }
          } label: {
            Text("Log it", tableName: "Log")
          }
          .buttonStyle(.shadowFilled)
          .disabled(!model.canSave)
        }
        Group {
          if remaining > 0 {
            Text("\(overview.loggedThisWeek) logged this week · \(remaining) rewarded entries left today", tableName: "Log")
          } else {
            Text("\(overview.loggedThisWeek) logged this week · today’s rewards are used; logging still works", tableName: "Log")
          }
        }
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        LogSaveFeedback(failureTitle: Text("Side quest not logged", tableName: "Log"), failure: model.failure, confirmation: model.confirmation)
        EntryCapNote(advisory: model.advisory)
      }
    }
  }

  private func list(_ overview: SideQuestsOverview) -> some View {
    @Bindable var model = model
    let items = model.items(in: overview)
    let visible = items.prefix(model.visibleCount)
    let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Group {
          if query.isEmpty {
            Text("\(overview.items.count) side quests", tableName: "Log")
          } else {
            Text("\(items.count) of \(overview.items.count) side quests", tableName: "Log")
          }
        }
        .shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        TextField(text: $model.search, prompt: Text("Search", tableName: "Log")) { Text("Search side quests", tableName: "Log") }
          .shadowField()
        if items.isEmpty {
          if query.isEmpty {
            ShadowContentUnavailable(Text("Nothing logged yet", tableName: "Log"), message: Text("The small things count here.", tableName: "Log"))
          } else {
            ShadowContentUnavailable(
              Text("Nothing matches “\(query)”", tableName: "Log"), kind: .noResults, message: Text("Try a different search.", tableName: "Log"))
          }
        }
        ForEach(visible, id: \.sideQuest.id) { item in
          HStack(spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
              Text(verbatim: item.sideQuest.name).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
              Text(verbatim: LogFormat.shortDate(item.sideQuest.date)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
            }
            Spacer()
            Text(verbatim: item.reward.map { "+\($0.xp)" } ?? "—").shadowFont(.body).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
              .accessibilityLabel(item.reward.map { Text("\($0.xp) XP", tableName: "Log") } ?? Text("No reward", tableName: "Log"))
          }
          .accessibilityElement(children: .combine)
        }
        if items.count > visible.count {
          Button {
            model.showMore()
          } label: {
            Text("Show more", tableName: "Log")
          }
          .buttonStyle(.shadowBordered)
        }
      }
    }
  }

  private func month(_ overview: SideQuestsOverview) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("This month", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        ShadowStatistic(
          Text("XP from side quests", tableName: "Log"), value: Text(overview.xpThisMonth, format: .number),
          caption: Text("\(overview.loggedThisMonth) logged", tableName: "Log"))
        Text("The first \(overview.rewardLimit) a day carry the reward. Anything after them still records — the log is the point, not the XP.", tableName: "Log")
          .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

#Preview {
  NavigationStack {
    if let context = try? MemoirScreenContext.inMemory() { SideQuestsView(context: context) }
  }
}
