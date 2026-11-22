import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/quests/quest-list-screen.tsx`: every quest, filtered to active, inactive or all and searched by name.
struct QuestsView: View {
  @State private var model: QuestListModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: QuestListModel(context: context))
  }

  var body: some View {
    @Bindable var model = model
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Text("Every promise you have made to yourself, active or kept as history.", tableName: "Quests")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        Picker(selection: $model.filter) {
          Text("Active", tableName: "Quests").tag(QuestFilter.active)
          Text("All", tableName: "Quests").tag(QuestFilter.all)
          Text("Inactive", tableName: "Quests").tag(QuestFilter.inactive)
        } label: {
          Text("Show", tableName: "Quests")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        content
      }
      .padding(Spacing.space4)
      .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .searchable(text: $model.search, prompt: Text("Search quests", tableName: "Quests"))
    .navigationTitle(Text("Quests", tableName: "Quests"))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        NavigationLink(value: MemoirRoute.quest(.new)) {
          Label(title: { Text("New quest", tableName: "Quests") }, icon: { Image(systemName: "plus") })
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .shadowBarItem()
      }
    }
    .shadowScreen(.root)
    .task(id: model.query) { await model.observe() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.listing.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("Quests couldn’t be loaded", tableName: "Quests"), kind: .error, message: error.text)
    case .loaded(let listing) where listing.all.entries.isEmpty:
      ShadowContentUnavailable(
        Text("No quests yet", tableName: "Quests"), systemImage: MemoirDestination.quests.systemImage,
        message: Text("A quest is a promise you make to yourself, kept one day at a time.", tableName: "Quests")
      ) {
        NavigationLink(value: MemoirRoute.quest(.new)) { Text("Create your first quest", tableName: "Quests") }.buttonStyle(.shadowFilled)
      }
    case .loaded(let listing):
      library(listing)
    }
  }

  @ViewBuilder
  private func library(_ listing: QuestListing) -> some View {
    filterNote(listing).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    if !listing.shown.entries.isEmpty {
      VStack(spacing: 0) {
        ForEach(listing.shown.entries) { summary in
          NavigationLink(value: MemoirRoute.quest(.detail(summary.id))) { QuestListRow(summary: summary) }
            .buttonStyle(.shadowRow)
          if summary.id != listing.shown.entries.last?.id { Divider() }
        }
      }
      .shadowCard()
    } else if listing.isSearching {
      ShadowContentUnavailable(
        Text("No quests match “\(listing.shown.search.trimmingCharacters(in: .whitespacesAndNewlines))”", tableName: "Quests"), kind: .noResults,
        message: Text("Try a different word, or clear the search to see every quest in this view.", tableName: "Quests")
      ) {
        Button {
          model.search = ""
        } label: {
          Text("Clear search", tableName: "Quests")
        }.buttonStyle(.shadowBordered)
      }
    } else {
      emptyFilter(listing.shown.filter)
    }
    if listing.shown.filter != .active {
      ShadowCallout(
        Text("Inactive quests keep their history", tableName: "Quests"),
        message: Text(
          "Pausing or archiving a quest never removes its XP, its streak record or its entries. Reactivating starts a new streak and leaves the old one in History as a closed record.",
          tableName: "Quests"), intent: .info)
    }
  }

  /// `filterNote` (`quest-list-screen.tsx:30-36`).
  private func filterNote(_ listing: QuestListing) -> Text {
    let total = listing.inFilter
    if listing.isSearching {
      let shown = listing.shown.entries.count
      return switch listing.shown.filter {
      case .active: Text("\(shown) of \(total) active quests", tableName: "Quests")
      case .inactive: Text("\(shown) of \(total) paused or archived quests", tableName: "Quests")
      case .all: Text("\(shown) of \(total) quests", tableName: "Quests")
      }
    }
    return switch listing.shown.filter {
    case .active: Text("\(total) active quests", tableName: "Quests")
    case .inactive: Text("\(total) paused or archived quests · history intact", tableName: "Quests")
    case .all: Text("\(total) quests in total", tableName: "Quests")
    }
  }

  private func emptyFilter(_ filter: QuestFilter) -> some View {
    switch filter {
    case .active:
      ShadowContentUnavailable(
        Text("No active quests", tableName: "Quests"),
        message: Text("Every quest is paused or archived. Reactivate one from Inactive, or make a new promise.", tableName: "Quests"))
    case .inactive:
      ShadowContentUnavailable(
        Text("No paused or archived quests", tableName: "Quests"),
        message: Text("Quests you pause or archive land here with their history intact.", tableName: "Quests"))
    case .all:
      ShadowContentUnavailable(
        Text("No quests yet", tableName: "Quests"), message: Text("A quest is a promise you make to yourself, kept one day at a time.", tableName: "Quests"))
    }
  }
}

/// `QuestListRow` (`quest-list-screen.tsx:146-182`).
private struct QuestListRow: View {
  let summary: QuestSummary

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        ShadowFlowLayout {
          Text(verbatim: QuestsCopy.name(summary.quest.name)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          ShadowTag(Text(verbatim: QuestsCopy.stat(summary.quest.statAffinity)))
          ShadowBadge(Text(verbatim: QuestsCopy.strictness(summary.quest.strictness)))
          if summary.lockedToday { ShadowBadge(Text("Locked plan", tableName: "Quests"), intent: .info, systemImage: "lock") }
        }
        Text(verbatim: QuestsCopy.meta(summary)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      Spacer(minLength: Spacing.space2)
      adherence
    }
    .padding(.vertical, Spacing.space2)
    .opacity(summary.quest.isActive ? 1 : ShadowOpacity.disabled)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var adherence: some View {
    if let ratio = summary.adherence.ratio {
      VStack(alignment: .trailing, spacing: 0) {
        Text(verbatim: QuestsCopy.percent(ratio)).shadowFont(.headline).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
        Text("30-day kept", tableName: "Quests").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
    } else {
      Text("Not enough history yet", tableName: "Quests").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).multilineTextAlignment(.trailing)
    }
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      QuestsView(context: context)
    }
  }
}
