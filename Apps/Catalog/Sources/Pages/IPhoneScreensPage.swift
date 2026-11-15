@_spi(Preview) import ShadowDesignSystem
import SwiftUI

enum IPhoneScreen: String, CaseIterable, Identifiable {
  case library
  case today
  case stepUp = "stepup"

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .library: "Web Novel · Library"
    case .today: "Memoir · Today"
    case .stepUp: "Identity step-up"
    }
  }
}

struct IPhoneScreensPage: View {
  @Environment(\.catalogScreen) private var launchScreen
  @State private var selection: IPhoneScreen?

  private var screen: Binding<IPhoneScreen> {
    Binding(get: { selection ?? launchScreen.flatMap(IPhoneScreen.init(rawValue:)) ?? .library }, set: { selection = $0 })
  }

  var body: some View {
    switch screen.wrappedValue {
    case .library: IPhoneLibraryScreen(screen: screen)
    case .today: IPhoneTodayScreen(screen: screen)
    case .stepUp: IPhoneStepUpScreen(screen: screen)
    }
  }
}

private struct IPhoneDemoItems: ToolbarContent {
  @Binding var screen: IPhoneScreen
  @Environment(\.catalogScreen) private var launchScreen

  var body: some ToolbarContent {
    CatalogDemoCloseItem()
    if launchScreen == nil {
      ToolbarItem(placement: CatalogDemoCloseItem.placement) {
        Menu("Screens", systemImage: "iphone") {
          Picker("Screen", selection: $screen) {
            ForEach(IPhoneScreen.allCases) { option in Text(option.title).tag(option) }
          }
        }
        .help("Switch screen")
        .shadowBarItem()
      }
    }
  }
}

private struct NoBooksFound: View {
  var body: some View {
    ShadowContentUnavailable("No results", kind: .noResults, message: "Try a title, an author or a tag.")
  }
}

private struct IPhoneLibraryScreen: View {
  @Binding var screen: IPhoneScreen

  var body: some View {
    TabView {
      Tab("Library", systemImage: "books.vertical") {
        NavigationStack { LibraryHome(screen: $screen) }
      }
      Tab("Browse", systemImage: "globe") {
        NavigationStack { LibraryBrowse(screen: $screen) }
      }
      Tab("Updates", systemImage: "bell") {
        NavigationStack { LibraryUpdates(screen: $screen) }
      }
      .badge(UpdateItem.sample.filter(\.isUnread).count)
      Tab(role: .search) {
        NavigationStack { LibrarySearch(screen: $screen) }
      }
    }
    #if os(iOS)
      .tabBarMinimizeBehavior(.onScrollDown)
      .tabViewBottomAccessory { ContinueReadingAccessory() }
    #endif
  }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
  case reading = "Reading"
  case saved = "Saved"
  case finished = "Finished"

  var id: Self { self }

  var books: [CatalogBook] {
    let shelf = CatalogBook.shelf
    switch self {
    case .reading: return Array(shelf[1...5])
    case .saved: return Array(shelf[6...7])
    case .finished: return [shelf[0]]
    }
  }
}

private struct LibraryHome: View {
  @Binding var screen: IPhoneScreen
  @State private var filter = LibraryFilter.reading
  @State private var query = ""

  private var books: [CatalogBook] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return filter.books }
    return CatalogBook.shelf.filter { $0.title.localizedStandardContains(trimmed) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        Picker("Filter", selection: $filter) {
          ForEach(LibraryFilter.allCases) { option in Text(LocalizedStringKey(option.rawValue)).tag(option) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        ContinueCard()
        if books.isEmpty {
          NoBooksFound()
        } else {
          ShadowGroupedSection {
            ForEach(books) { book in
              ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), accessory: .chevron) {
                ListCover(book: book)
              } trailing: {
                if book.id == "G&A" { ShadowBadge(count: 2) }
              }
            }
          } header: {
            ShadowSectionHeader(LocalizedStringKey(filter.rawValue))
          }
        }
      }
      .padding(DemoLayout.margin)
    }
    .catalogScrollAnchor()
    .navigationTitle("Library")
    .shadowScreen(.root)
    .demoSearchable(text: $query, prompt: "Titles, authors, tags")
    .toolbar {
      IPhoneDemoItems(screen: $screen)
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Filter", systemImage: "line.3.horizontal.decrease") {}
          .shadowBarItem()
        DemoAccountMenu(labelStyle: .avatar)
      }
    }
  }
}

private struct ContinueCard: View {
  var body: some View {
    let book = CatalogBook.shelf[0]
    ShadowCard {
      HStack(alignment: .top, spacing: Spacing.space3) {
        CoverArt(book: book, showsTitle: false)
          .frame(width: 64, height: 92)
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text("Continue")
            .shadowFont(.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(ShadowColor.accentText)
          Text(verbatim: book.title)
            .shadowFont(.headline)
            .foregroundStyle(ShadowColor.textPrimary)
          Text(verbatim: "Chapter 42 · The Glass Stair")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
          ProgressView(value: 0.68)
            .progressViewStyle(.shadowLinear)
            .padding(.top, Spacing.space1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Button {
      } label: {
        Text("Continue reading").frame(maxWidth: .infinity)
      }
      .buttonStyle(.shadowFilled)
      .controlSize(.large)
    }
  }
}

private struct LibraryBrowse: View {
  @Binding var screen: IPhoneScreen

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space6) {
        DemoCoverGrid(books: CatalogBook.shelf)
        ShadowGroupedSection {
          DemoBookRows(books: Array(CatalogBook.shelf.prefix(4)))
        } header: {
          ShadowSectionHeader("New this week")
        }
      }
      .padding(DemoLayout.margin)
    }
    .navigationTitle("Browse")
    .shadowScreen(.root)
    .toolbar { IPhoneDemoItems(screen: $screen) }
  }
}

private struct LibraryUpdates: View {
  @Binding var screen: IPhoneScreen

  var body: some View {
    List {
      ForEach(UpdateItem.sample) { item in
        ShadowListRow(title: Text(verbatim: item.title), subtitle: Text(verbatim: item.detail), accessory: .chevron) {
          ShadowSymbolTile(systemImage: item.isUnread ? "bell.badge" : "bell", tint: item.isUnread ? .accent : .neutral)
        }
      }
    }
    .shadowListStyle()
    .navigationTitle("Updates")
    .shadowScreen(.root)
    .toolbar { IPhoneDemoItems(screen: $screen) }
  }
}

private struct LibrarySearch: View {
  @Binding var screen: IPhoneScreen
  @State private var query = ""

  private var results: [CatalogBook] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return CatalogBook.shelf }
    return CatalogBook.shelf.filter { $0.title.localizedStandardContains(trimmed) }
  }

  var body: some View {
    List {
      if results.isEmpty {
        NoBooksFound()
          .listRowBackground(Color.clear)
      } else {
        ForEach(results) { book in
          ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress)) { ListCover(book: book) }
        }
      }
    }
    .shadowListStyle()
    .navigationTitle("Search")
    .shadowScreen(.root)
    .searchable(text: $query, prompt: "Titles, authors, tags")
    .toolbar { IPhoneDemoItems(screen: $screen) }
  }
}

private struct DailyQuest: Identifiable {
  let id: Int
  let title: LocalizedStringKey
}

private let dailyQuests = [
  DailyQuest(id: 0, title: "Walk 6,000 steps"),
  DailyQuest(id: 1, title: "Log today’s spending"),
  DailyQuest(id: 2, title: "Drink 2 litres of water"),
  DailyQuest(id: 3, title: "Read for 20 minutes"),
  DailyQuest(id: 4, title: "Stretch for 10 minutes"),
]

private struct ChecklistToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button {
      configuration.isOn.toggle()
    } label: {
      HStack(spacing: Spacing.space3) {
        QuestCheckGlyph(isDone: configuration.isOn)
        configuration.label
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: ShadowMetrics.rowTouch)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(.isToggle)
    .accessibilityValue(configuration.isOn ? Text("Done") : Text("Not done"))
  }
}

private struct IPhoneTodayScreen: View {
  @Binding var screen: IPhoneScreen
  @State private var done: Set<Int> = [0, 1, 2]
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    TabView {
      Tab("Today", systemImage: "house") {
        NavigationStack { today }
      }
      Tab("Quests", systemImage: "scope") {
        NavigationStack { placeholder("Quests") }
      }
      Tab("Insights", systemImage: "sparkles") {
        NavigationStack { placeholder("Insights") }
      }
    }
    #if os(iOS)
      .tabBarMinimizeBehavior(.onScrollDown)
    #endif
  }

  private func placeholder(_ title: LocalizedStringKey) -> some View {
    ShadowContentUnavailable("Nothing here yet", message: "This tab is outside the demo.")
      .navigationTitle(title)
      .shadowScreen(.root)
      .toolbar { IPhoneDemoItems(screen: $screen) }
  }

  private var today: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        level
        quests
        ShadowGroupedSection {
          ShadowListRow(title: Text("Spent today"), subtitle: Text("$23.40 of $40 budget"), value: Text("58%")) { ShadowSymbolTile(systemImage: "creditcard") }
          ShadowListRow(title: Text("Weigh-in"), subtitle: Text("Step on the scale when it suits you"), accessory: .chevron) {
            ShadowSymbolTile(systemImage: "scalemass")
          }
          ShadowListRow(title: Text("Insights"), subtitle: Text("Your best week for steps since August"), accessory: .chevron) {
            ShadowSymbolTile(systemImage: "sparkles")
          }
        } header: {
          ShadowSectionHeader("Finance and health")
        }
      }
      .padding(DemoLayout.margin)
    }
    .catalogScrollAnchor()
    .navigationTitle("Today")
    .shadowScreen(.root)
    .toolbar {
      IPhoneDemoItems(screen: $screen)
      ToolbarItem(placement: .primaryAction) { DemoAccountMenu(labelStyle: .avatar) }
    }
  }

  private var level: some View {
    let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space3)) : AnyLayout(HStackLayout(spacing: Spacing.space4))
    return ShadowCard {
      layout {
        ProgressView(value: 2_340, total: 3_340)
          .progressViewStyle(.shadowRing)
          .controlSize(.large)
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text("Level 12 · Wayfinder")
            .shadowFont(.footnote)
            .fontWeight(.medium)
            .foregroundStyle(ShadowColor.textSecondary)
          Text("2,340 XP")
            .shadowFont(.title)
            .monospacedDigit()
            .foregroundStyle(ShadowColor.textPrimary)
          Text("1,000 XP to level 13")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private var quests: some View {
    ShadowCard {
      VStack(spacing: 0) {
        ForEach(dailyQuests) { quest in
          Toggle(isOn: binding(for: quest.id)) { Text(quest.title) }
            .toggleStyle(ChecklistToggleStyle())
        }
      }
    } header: {
      ShadowCardHeader("Daily quests", subtitle: "\(done.count) of \(dailyQuests.count) done") {
        ShadowBadge("12 days", intent: .info, systemImage: "flame")
      }
    }
  }

  private func binding(for id: Int) -> Binding<Bool> {
    Binding(
      get: { done.contains(id) },
      set: { isOn in
        if isOn { done.insert(id) } else { done.remove(id) }
      })
  }
}

private struct IPhoneStepUpScreen: View {
  @Binding var screen: IPhoneScreen
  @State private var showsSheet = true

  var body: some View {
    NavigationStack {
      ScrollView { DemoReader() }
        .catalogScrollAnchor()
        .navigationTitle("Chapter 42")
        .shadowScreen(.pushed)
        .toolbar {
          IPhoneDemoItems(screen: $screen)
          ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: "ellipsis") {
              Button("Finalize into canon…", systemImage: "checkmark.circle") { showsSheet = true }
            }
            .shadowBarItem()
          }
        }
    }
    .sheet(isPresented: $showsSheet) {
      StepUpSheet().shadowSheetStyle(.partial)
    }
  }
}

private struct StepUpSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var code = "482"
  @Environment(\.catalogScreen) private var launchScreen

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.space4) {
        ShadowSymbolTile(systemImage: "shield", style: .filled, size: .large)
        Text("Finalizing into canon needs a fresh check. Enter the 6-digit code from your authenticator app.")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
          .multilineTextAlignment(.center)
        ShadowOneTimeCodeField("Verification code", code: $code, value: { Text("\($0.entered) of \($0.length) digits entered") }) { _ in dismiss() }
          .shadowPreviewFieldFocus(launchScreen == nil ? nil : true)
        Button {
          dismiss()
        } label: {
          Text("Verify").frame(maxWidth: .infinity)
        }
        .buttonStyle(.shadowFilled)
        .controlSize(.large)
        .disabled(code.count < 6)
        Button("Use a passkey instead", systemImage: "person.badge.key") {}
          .buttonStyle(.shadowPlain)
      }
      .padding(.horizontal, DemoLayout.margin)
      .padding(.bottom, Spacing.space4)
    }
    .shadowSheetHeader(Text("Confirm it’s you"), cancel: ShadowSheetCancel("Close") { dismiss() })
  }
}
