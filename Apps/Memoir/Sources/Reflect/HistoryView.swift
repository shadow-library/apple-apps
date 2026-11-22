import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// `features/history/index.tsx`: one stream of everything logged, newest first, filtered by kind, searched, paged, and a record's details beside it on a
/// wide screen or pushed on a narrow one.
struct HistoryView: View {
  @State private var model: HistoryModel
  private let context: MemoirScreenContext

  init(context: MemoirScreenContext) {
    self.context = context
    _model = State(initialValue: HistoryModel(context: context))
  }

  var body: some View {
    HistoryScreen(model: model, context: context)
  }
}

private struct HistoryScreen: View {
  @Bindable var model: HistoryModel
  let context: MemoirScreenContext
  @State private var generation = 0
  @Environment(\.horizontalSizeClass) private var sizeClass

  private var isWide: Bool { sizeClass != .compact }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Text("One stream of everything you have logged, newest first. Nothing here is deleted by a later correction — it is kept beside it.", tableName: "Reflect")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        filters
        if isWide {
          HStack(alignment: .top, spacing: Spacing.space5) {
            stream.frame(maxWidth: ShadowMetrics.readableWidth)
            aside.frame(width: ShadowMetrics.inspector)
          }
        } else {
          stream
          totals
        }
      }
      .padding(Spacing.space4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(ShadowColor.surfaceApp)
    .searchable(text: $model.searchText, prompt: Text("Search everything you have logged", tableName: "Reflect"))
    .navigationTitle(Text(MemoirDestination.history.title))
    .shadowScreen(.root)
    .task { await model.followToday() }
    .task { await model.observeLookups() }
    .task(id: model.searchText) { await model.applySearchAfterPause() }
    .task(id: ObservationKey(read: model.readKey, generation: generation)) { await model.observe() }
  }

  private var filters: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
        ForEach(HistoryModel.filters, id: \.self) { kind in
          ShadowTag(
            Text(verbatim: kind.map(ReflectCopy.kind) ?? ReflectCopy.everything),
            isSelected: Binding(get: { model.kind == kind }, set: { if $0 { model.filter(kind) } }))
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Text("Record type", tableName: "Reflect"))
      if model.kindIsNotHeld {
        ShadowCallout(Text("Not kept on this device", tableName: "Reflect"), message: Text(verbatim: ReflectCopy.missingClasses(model.bodyClasses).joined(separator: " ")))
      }
    }
  }

  @ViewBuilder
  private var stream: some View {
    if let failure = model.day.failure {
      ShadowContentUnavailable(Text("History couldn’t be loaded", tableName: "Reflect"), kind: .error, message: failure.text)
    } else {
      switch model.history.state {
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
      case .loaded(let page) where page.totalRecords == 0:
        ShadowContentUnavailable(
          Text("Nothing logged yet", tableName: "Reflect"), systemImage: MemoirDestination.history.systemImage,
          message: Text("Everything you record — quests, money, journal, meals, weight and health — will show up here as you go.", tableName: "Reflect"))
      case .loaded(let page):
        records(page)
      }
    }
  }

  @ViewBuilder
  private func records(_ page: HistoryPage) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(verbatim: HistoryTotalsCopy.count(matched: model.isFiltered ? page.records.total : page.totalRecords, isFiltered: model.isFiltered))
        .shadowFont(.headline)
        .foregroundStyle(ShadowColor.textPrimary)
      Text("Quests, hero events, money, journal, meals, weight and health, in one place.", tableName: "Reflect")
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
    }
    if page.records.items.isEmpty {
      ShadowContentUnavailable(
        Text("Nothing matches that yet", tableName: "Reflect"), kind: .noResults,
        message: Text("Try a different record type, or clear the search. Everything you have logged is still here.", tableName: "Reflect")
      ) {
        Button {
          model.clearFilters()
        } label: {
          Text("Clear the filters", tableName: "Reflect")
        }
        .buttonStyle(.shadowBordered)
      }
    } else {
      ForEach(model.groups) { group in
        VStack(alignment: .leading, spacing: Spacing.space2) {
          Text(verbatim: group.label)
            .shadowFont(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(ShadowColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
          VStack(spacing: 0) {
            ForEach(group.rows, id: \.id) { row in
              rowLink(row)
              if row.id != group.rows.last?.id { Divider() }
            }
          }
          .shadowCard()
        }
      }
      pager
    }
  }

  @ViewBuilder
  private func rowLink(_ row: HistoryPresentation) -> some View {
    if isWide {
      Button {
        model.selection = row.id
      } label: {
        HistoryRow(row: row, isSelected: model.selection == row.id)
      }
      .buttonStyle(.shadowRow)
      .accessibilityAddTraits(model.selection == row.id ? .isSelected : [])
    } else {
      NavigationLink(value: MemoirRoute.reflect(.record(row.id))) {
        HistoryRow(row: row, isSelected: false)
      }
      .buttonStyle(.shadowRow)
    }
  }

  @ViewBuilder
  private var pager: some View {
    if model.pageCount > 1 {
      HStack(spacing: Spacing.space3) {
        Button {
          model.go(to: model.page - 1)
        } label: {
          Label {
            Text("Previous page", tableName: "Reflect")
          } icon: {
            Image(systemName: "chevron.left")
          }
        }
        .disabled(model.page <= 1)
        Spacer(minLength: Spacing.space2)
        Text("Page \(model.page) of \(model.pageCount)", tableName: "Reflect")
          .shadowFont(.footnote)
          .monospacedDigit()
          .foregroundStyle(ShadowColor.textSecondary)
        Spacer(minLength: Spacing.space2)
        Button {
          model.go(to: model.page + 1)
        } label: {
          HStack(spacing: Spacing.space1) {
            Text("Next page", tableName: "Reflect")
            Image(systemName: "chevron.right").accessibilityHidden(true)
          }
        }
        .disabled(model.page >= model.pageCount)
      }
      .buttonStyle(.shadowBordered)
    }
  }

  @ViewBuilder
  private var aside: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      if let page = model.history.state.value, page.totalRecords > 0 {
        if let selection = model.selection {
          HistoryRecordPane(
            context: context, id: selection, kind: model.kind, search: model.search, listed: model.rows.first { $0.id == selection },
            bodyClasses: model.bodyClasses
          )
          .id(PaneKey(id: selection, kind: model.kind))
        } else {
          Text("Select a record to see its details.", tableName: "Reflect")
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textSecondary)
            .shadowCard()
        }
      }
      totals
    }
  }

  @ViewBuilder
  private var totals: some View {
    if let page = model.history.state.value, page.totalRecords > 0 {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text("Totals for this view", tableName: "Reflect")
          .shadowFont(.headline)
          .foregroundStyle(ShadowColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        ForEach(HistoryTotalsCopy.lines(page.totals), id: \.self) { line in
          Text(verbatim: line).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .shadowCard()
    }
  }

  private struct ObservationKey: Hashable {
    let read: HistoryReadKey?
    let generation: Int
  }

  private struct PaneKey: Hashable {
    let id: String
    let kind: HistoryKind?
  }
}

private struct HistoryRow: View {
  let row: HistoryPresentation
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        HStack(spacing: Spacing.space2) {
          ShadowBadge(Text(verbatim: ReflectCopy.kind(row.kind)))
          if let time = row.time {
            Text(verbatim: time).shadowFont(.caption).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
          }
        }
        Text(verbatim: row.text)
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textPrimary)
          .lineLimit(2)
      }
      Spacer(minLength: Spacing.space2)
      Text(verbatim: row.value).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
    }
    .padding(.vertical, Spacing.space2)
    .padding(.horizontal, Spacing.space1)
    .background(isSelected ? ShadowColor.selectionRow : .clear, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// The details of the record selected on a wide screen: the row on the page shown when it is there, otherwise the record among those the current
/// filter and search keep.
private struct HistoryRecordPane: View {
  @State private var model: HistoryRecordModel
  let search: String
  let listed: HistoryPresentation?

  init(context: MemoirScreenContext, id: String, kind: HistoryKind?, search: String, listed: HistoryPresentation?, bodyClasses: Set<SyncClass>) {
    _model = State(initialValue: HistoryRecordModel(context: context, id: id, kind: kind, search: search, bodyClasses: bodyClasses))
    self.search = search
    self.listed = listed
  }

  var body: some View {
    Group {
      if let failure = model.day.failure {
        ShadowContentUnavailable(Text("Couldn’t load this right now", tableName: "Reflect"), kind: .error, message: failure.text)
      } else if let listed {
        HistoryRecordDetail(presentation: listed, today: model.day.day?.today)
      } else {
        switch model.presentation {
        case .loading:
          ProgressView().frame(maxWidth: .infinity)
        case .failed(let error):
          ShadowContentUnavailable(Text("Couldn’t load this right now", tableName: "Reflect"), kind: .error, message: error.text)
        case .missing:
          Text("This record doesn’t match the current filter or search.", tableName: "Reflect")
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textSecondary)
        case .found(let presentation):
          HistoryRecordDetail(presentation: presentation, today: model.day.day?.today)
        }
      }
    }
    .shadowCard()
    .task { await model.followToday() }
    .task { await model.observeLookups() }
    .task(id: PaneRead(today: model.day.day?.today, search: search)) {
      model.search = search
      await model.observe()
    }
  }

  private struct PaneRead: Hashable {
    let today: LocalDate?
    let search: String
  }
}

/// `features/history` detail card: the kind, the title, when, the fields and the way to the screen that owns the record.
struct HistoryRecordDetail: View {
  let presentation: HistoryPresentation
  let today: LocalDate?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        Text(verbatim: ReflectCopy.kind(presentation.kind))
          .shadowFont(.caption)
          .foregroundStyle(ShadowColor.textSecondary)
        Text(verbatim: presentation.title)
          .shadowFont(.title3)
          .foregroundStyle(ShadowColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: presentation.when(today: today))
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
      }
      VStack(alignment: .leading, spacing: Spacing.space2) {
        ForEach(presentation.fields, id: \.self) { field in
          LabeledContent {
            Text(verbatim: field.value).foregroundStyle(ShadowColor.textPrimary).multilineTextAlignment(.trailing)
          } label: {
            Text(verbatim: field.label).foregroundStyle(ShadowColor.textSecondary)
          }
          .shadowFont(.subheadline)
        }
      }
      NavigationLink(value: presentation.link.route) {
        Text("Open in \(presentation.link.section)", tableName: "Reflect")
      }
      .buttonStyle(.shadowBordered)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      HistoryView(context: context)
    }
  }
}
