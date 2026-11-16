import ShadowDesignSystem
import SwiftUI

private nonisolated enum ForgeStatus: Int, Comparable, Sendable {
  case inReview
  case canon
  case planned

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension ForgeStatus {
  fileprivate var badge: ShadowBadge {
    switch self {
    case .inReview: ShadowBadge("In review", intent: .warning, systemImage: "pencil")
    case .canon: ShadowBadge("Canon", intent: .success, systemImage: "checkmark")
    case .planned: ShadowBadge("Planned", intent: .neutral, systemImage: "clock")
    }
  }
}

private nonisolated struct ForgeChapter: Identifiable, Hashable, Sendable {
  let id: Int
  let title: String
  let words: Int
  let status: ForgeStatus

  var wordCount: String { words == 0 ? "—" : words.formatted(.number) }

  static let all: [ForgeChapter] = [
    ForgeChapter(id: 42, title: "The Glass Stair", words: 3_214, status: .inReview),
    ForgeChapter(id: 41, title: "Ink and Salt", words: 2_980, status: .canon),
    ForgeChapter(id: 40, title: "A Door of Moths", words: 3_402, status: .canon),
    ForgeChapter(id: 39, title: "The Archivist Lies", words: 3_118, status: .canon),
    ForgeChapter(id: 38, title: "Lanterns Out", words: 2_744, status: .canon),
    ForgeChapter(id: 37, title: "Salt Road", words: 3_051, status: .canon),
    ForgeChapter(id: 43, title: "Ash Garden", words: 0, status: .planned),
  ]
}

private enum ForgeFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case drafts = "Drafts"
  case inReview = "In review"
  case canon = "Canon"

  var id: Self { self }

  var status: ForgeStatus? {
    switch self {
    case .all: nil
    case .drafts: .planned
    case .inReview: .inReview
    case .canon: .canon
    }
  }
}

private enum ForgeDestination: Hashable, CaseIterable {
  case chapters
  case storyBible
  case secrets
  case canon
  case aiDrafts
  case settings

  var title: String {
    switch self {
    case .chapters: "Chapters"
    case .storyBible: "Story Bible"
    case .secrets: "Secrets"
    case .canon: "Canon"
    case .aiDrafts: "AI drafts"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .chapters: "book"
    case .storyBible: "doc.text"
    case .secrets: "lock"
    case .canon: "checkmark.circle"
    case .aiDrafts: "sparkles"
    case .settings: "slider.horizontal.3"
    }
  }

  var badge: ShadowSidebarBadge? {
    switch self {
    case .chapters: .count(43)
    case .secrets: .alert(2)
    case .aiDrafts: .count(3)
    default: nil
    }
  }
}

struct IPadScreenPage: View {
  @State private var destination: ForgeDestination? = .chapters
  @State private var compactColumn = NavigationSplitViewColumn.detail
  @State private var organization = ForgeOrganization.all[0].id

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      List(selection: $destination) {
        Section {
          ForEach([ForgeDestination.chapters, .storyBible, .secrets]) { item in ForgeSidebarRow(item: item) }
        } header: {
          ShadowSidebarHeader("Writing")
        }
        Section {
          ForEach([ForgeDestination.canon, .aiDrafts]) { item in ForgeSidebarRow(item: item) }
        } header: {
          ShadowSidebarHeader("Review")
        }
        Section {
          ForgeSidebarRow(item: .settings)
        } header: {
          ShadowSidebarHeader("Novel")
        }
      }
      .shadowListStyle(.sidebar)
      .safeAreaInset(edge: .top) {
        ShadowOrganizationSwitcher("Switch novel", organizations: ForgeOrganization.all, selection: $organization)
          .padding(.horizontal, DemoLayout.margin)
          .padding(.vertical, Spacing.space2)
      }
      .navigationTitle("Novel Forge")
      .shadowColumnWidth(.sidebar)
      .toolbar { CatalogDemoCloseItem() }
    } detail: {
      ForgeChapters()
    }
  }
}

private enum ForgeOrganization {
  static let all = [
    ShadowOrganization(id: "ninth-archive", name: "The Ninth Archive", detail: "Novel Forge"),
    ShadowOrganization(id: "glass-and-ash", name: "Glass and Ash", detail: "Novel Forge"),
    ShadowOrganization(id: "salt-kings", name: "Salt Kings", detail: "Novel Forge"),
  ]
}

extension ForgeDestination: Identifiable {
  fileprivate var id: Self { self }
}

private struct ForgeSidebarRow: View {
  let item: ForgeDestination

  var body: some View {
    ShadowSidebarLabel(Text(verbatim: item.title), systemImage: item.systemImage, badge: item.badge)
      .tag(item)
  }
}

private struct ForgeChapters: View {
  @State private var filter = ForgeFilter.all
  @State private var selection: Set<ForgeChapter.ID> = [42]
  @State private var sortOrder: [KeyPathComparator<ForgeChapter>] = []
  @State private var showsInspector = false
  @State private var hasChosenInspector = false

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  private var presentsAsSheet: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private static let inspectorThreshold: CGFloat = 900

  private var rows: [ForgeChapter] {
    ForgeChapter.all.filter { filter.status == nil || $0.status == filter.status }.sorted(using: sortOrder)
  }

  private var selected: ForgeChapter? {
    ForgeChapter.all.first { selection.contains($0.id) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Picker("Filter", selection: $filter) {
          ForEach(ForgeFilter.allCases) { option in Text(LocalizedStringKey(option.rawValue)).tag(option) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        table
        ShadowCallout("Synapse budget at 82%", message: "AI drafting pauses at 100% this month. Drafting by hand still works.", intent: .warning)
      }
      .padding(DemoLayout.margin)
    }
    .catalogScrollAnchor()
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: { width in
      guard !hasChosenInspector else { return }
      hasChosenInspector = true
      showsInspector = DemoPlatform.opensDetail && width >= Self.inspectorThreshold
    }
    .navigationTitle("Chapters")
    .demoSubtitle("The Ninth Archive")
    .shadowScreen(.root)
    .toolbar {
      if presentsAsSheet {
        ToolbarItem(placement: .primaryAction) {
          Menu("More", systemImage: "ellipsis") {
            filterActions
            Divider()
            moreActions
          }
          .shadowBarItem()
        }
      } else {
        ToolbarItemGroup(placement: .primaryAction) {
          Menu("Filter", systemImage: "line.3.horizontal.decrease") { filterActions }
            .shadowBarItem()
          Menu("More", systemImage: "ellipsis") { moreActions }
            .shadowBarItem()
          InspectorToggle(isPresented: $showsInspector)
        }
      }
      #if !os(visionOS)
        ToolbarSpacer(.fixed, placement: .primaryAction)
      #endif
      ToolbarItem(placement: .confirmationAction) {
        Button("New", systemImage: "plus") {}
          .shadowToolbarProminent()
      }
    }
    .demoInspector(isPresented: $showsInspector) {
      ForgeInspector(chapter: selected, presentsAsSheet: presentsAsSheet, isPresented: $showsInspector)
        .shadowColumnWidth(.inspector)
        .presentationDetents([.medium, .large])
    }
  }

  @ViewBuilder
  private var filterActions: some View {
    Button("Needs review", systemImage: "eye") { filter = .inReview }
    Button("Show all", systemImage: "list.bullet") { filter = .all }
  }

  @ViewBuilder
  private var moreActions: some View {
    Button("Export as EPUB…", systemImage: "square.and.arrow.up") {}
    Button("Renumber chapters", systemImage: "number") {}
  }

  private var table: some View {
    ShadowTable(rows, selection: $selection, sortOrder: $sortOrder) {
      TableColumn(Text("#").shadowTableHeader(), value: \.id) { ShadowTableNumber(Text($0.id, format: .number.grouping(.never))).shadowTableCell(row: $0) }
        .width(min: 36, ideal: 44, max: 64)
      TableColumn(Text("Title").shadowTableHeader(), value: \.title) { Text(verbatim: $0.title).shadowTableCell(row: $0) }
        .width(min: 120, ideal: 200)
      TableColumn(Text("Words").shadowTableHeader(), value: \.words) { ShadowTableNumber(Text(verbatim: $0.wordCount)).shadowTableCell(row: $0) }
        .width(min: 56, ideal: 64)
        .alignment(.trailing)
      TableColumn(Text("Status").shadowTableHeader(), value: \.status) { $0.status.badge.shadowTableCell(row: $0) }
        .width(112)
    } compact: { chapter in
      ShadowListRow(
        title: Text(verbatim: "\(chapter.id) · \(chapter.title)"), subtitle: Text(verbatim: "\(chapter.wordCount) words"), isSelected: selection.contains(chapter.id),
        trailing: chapter.status.badge)
    }
    .demoTableFrame(.fitsContent(estimatedRows: rows.count))
  }
}

private struct ForgeEvent: Identifiable {
  let id: Int
  let status: ShadowTimelineStatus
  let title: LocalizedStringKey
  let detail: LocalizedStringKey?
  let time: LocalizedStringKey?
}

private struct ForgeInspector: View {
  let chapter: ForgeChapter?
  let presentsAsSheet: Bool
  @Binding var isPresented: Bool

  private var events: [ForgeEvent] {
    guard let chapter else { return [] }
    switch chapter.status {
    case .inReview:
      return [
        ForgeEvent(id: 1, status: .completed, title: "Planned with you", detail: nil, time: "12 Nov"),
        ForgeEvent(id: 2, status: .completed, title: "Drafted by AI", detail: nil, time: "13 Nov"),
        ForgeEvent(id: 3, status: .current, title: "In review", detail: "2 comments open", time: nil),
        ForgeEvent(id: 4, status: .upcoming, title: "Finalize into canon", detail: "Needs step-up", time: nil),
      ]
    case .canon:
      return [
        ForgeEvent(id: 1, status: .completed, title: "Planned with you", detail: nil, time: "2 Nov"),
        ForgeEvent(id: 2, status: .completed, title: "Drafted by AI", detail: nil, time: "4 Nov"),
        ForgeEvent(id: 3, status: .completed, title: "Reviewed", detail: nil, time: "8 Nov"),
        ForgeEvent(id: 4, status: .completed, title: "Finalized into canon", detail: nil, time: "9 Nov"),
      ]
    case .planned:
      return [
        ForgeEvent(id: 1, status: .current, title: "Planned with you", detail: "Outline only", time: nil),
        ForgeEvent(id: 2, status: .upcoming, title: "Draft with AI", detail: nil, time: nil),
        ForgeEvent(id: 3, status: .upcoming, title: "Review", detail: nil, time: nil),
        ForgeEvent(id: 4, status: .upcoming, title: "Finalize into canon", detail: "Needs step-up", time: nil),
      ]
    }
  }

  var body: some View {
    if let chapter {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space5) {
          header(chapter)
          ShadowDetailsForm {
            ShadowLabeledContent("Status") { chapter.status.badge }
            ShadowLabeledContent("Words", value: chapter.words == 0 ? "—" : "\(chapter.wordCount) of 3,000")
            ShadowLabeledContent("Drafted by", value: chapter.status == .planned ? "—" : "AI · Synapse")
            ShadowLabeledContent("Unlocks", value: "The Archivist’s true name")
          }
          ShadowTimeline(events) { event in
            ShadowTimelineItem(
              status: event.status, title: Text(event.title), detail: event.detail.map { Text($0) }, time: event.time.map { Text($0) })
          }
        }
        .padding(DemoLayout.margin)
      }
      .safeAreaInset(edge: .bottom) {
        Button {
        } label: {
          Label("Finalize into canon", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.shadowFilled)
        .controlSize(.large)
        .disabled(chapter.status != .inReview)
        .padding(DemoLayout.margin)
      }
    } else {
      ShadowContentUnavailable("No chapter selected", message: "Select a chapter to see its details.")
    }
  }

  private func header(_ chapter: ForgeChapter) -> some View {
    HStack {
      Text("Chapter \(chapter.id)")
        .shadowFont(.title3)
        .foregroundStyle(ShadowColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      ShadowIconButton("Close", systemImage: "xmark") { isPresented = false }
        .foregroundStyle(ShadowColor.accentText)
    }
  }
}
