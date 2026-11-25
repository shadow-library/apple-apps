import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

enum HeroTab: String, CaseIterable, Hashable, Identifiable {
  case overview
  case achievements
  case titles
  case cosmetics

  var id: Self { self }

  var title: Text {
    switch self {
    case .overview: Text("Overview", tableName: "Hero")
    case .achievements: Text("Achievements", tableName: "Hero")
    case .titles: Text("Titles", tableName: "Hero")
    case .cosmetics: Text("Cosmetics", tableName: "Hero")
    }
  }
}

struct HeroView: View {
  @State private var model: HeroModel
  @State private var game: MoneyGameModel
  @State private var tab = HeroTab.overview
  @State private var generation = 0
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(MemoirModules.self) private var modules: MemoirModules?

  init(context: MemoirScreenContext) {
    _model = State(initialValue: HeroModel(context: context))
    _game = State(initialValue: MoneyGameModel(context: context))
  }

  private var showsMoney: Bool { modules?.selection.contains(.money) ?? true }

  /// Every choice Coming back offers is kept on Today or the Planning Board, so it goes with Quests.
  private var offersComingBack: Bool { modules?.shows(.destination(.today)) ?? true }

  var body: some View {
    content
      .navigationTitle(Text("Hero", tableName: "Hero"))
      .task(id: generation) { await model.run() }
      .task(id: showsMoney) {
        guard showsMoney else { return }
        await game.run()
      }
      .toolbar { comingBackLink }
      .alert(
        failureTitle, isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }), presenting: model.failure
      ) { _ in
        Button {
          model.failure = nil
        } label: {
          Text("OK", tableName: "Hero")
        }
      } message: { failure in
        failure.error.text
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.deck.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).shadowScreen(.root)
    case .failed(let error):
      ShadowContentUnavailable(Text("Your hero couldn’t be read", tableName: "Hero"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Hero")
        }
      }
      .fillingSurface()
      .shadowScreen(.root)
    case .loaded(let deck):
      loaded(deck)
    }
  }

  private func loaded(_ deck: HeroDeck) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        Text("Everything you have earned, and nothing you can lose. Experience only ever goes up.", tableName: "Hero")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        if deck.halt != nil {
          ShadowCallout(
            Text("Memoir needs updating", tableName: "Hero"),
            message: Text("A change from another device needs a newer version of Memoir. Your hero shows everything up to it until you update.", tableName: "Hero"),
            intent: .warning)
        }
        HeroCrestCard(deck: deck)
        HeroStatsGrid(stats: deck.stats)
        HeroTabPicker(tab: $tab)
        switch tab {
        case .overview: HeroOverviewSection(deck: deck, today: model.today, money: showsMoney ? game.snapshot : nil)
        case .achievements: HeroAchievementsSection(achievements: deck.achievements)
        case .titles: HeroTitlesSection(deck: deck, model: model)
        case .cosmetics: HeroCosmeticsSection(deck: deck, model: model)
        }
      }
      .padding(sizeClass == .compact ? Spacing.space4 : Spacing.space6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .shadowScreen(.root)
  }

  @ToolbarContentBuilder
  private var comingBackLink: some ToolbarContent {
    if model.deck.state.value?.comingBack != nil, offersComingBack {
      ToolbarItem {
        NavigationLink(value: MemoirRoute.hero(.comingBack)) {
          Label(title: { Text("Coming back", tableName: "Hero") }, icon: { Image(systemName: "arrow.uturn.backward.circle") })
        }
        .shadowBarItem()
      }
    }
  }

  private var failureTitle: Text {
    switch model.failure?.action {
    case .display(let title)?: Text("Couldn’t display ‘\(HeroCatalogue.name(of: title))’", tableName: "Hero")
    case .clearTitle?: Text("Couldn’t clear the displayed title", tableName: "Hero")
    case .unlock(let cosmetic)?: Text("Couldn’t unlock ‘\(HeroCatalogue.name(of: cosmetic))’", tableName: "Hero")
    case .equip(let cosmetic)?: Text("Couldn’t equip ‘\(HeroCatalogue.name(of: cosmetic))’", tableName: "Hero")
    case nil: Text(verbatim: "")
    }
  }
}

struct HeroTabPicker: View {
  @Binding var tab: HeroTab
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      picker.pickerStyle(.menu)
    } else {
      picker.pickerStyle(.segmented)
    }
  }

  private var picker: some View {
    Picker(selection: $tab) {
      ForEach(HeroTab.allCases) { tab in tab.title.tag(tab) }
    } label: {
      Text("Hero sections", tableName: "Hero")
    }
    .labelsHidden()
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack { HeroView(context: context) }.shadowTheme()
  }
}
