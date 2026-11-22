import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct OverviewView: View {
  let context: NovelContext
  @Environment(LibraryModel.self) private var library
  @State private var observer = ReadObserver<NovelOverview>()
  @State private var checklist: ChecklistModel
  @State private var exporter: ExportModel
  @State private var generation = 0

  init(context: NovelContext) {
    self.context = context
    _checklist = State(initialValue: ChecklistModel(context: context))
    _exporter = State(initialValue: ExportModel(context: context))
  }

  var body: some View {
    content
      .navigationTitle(Text(NovelSection.overview.title))
      .task(id: generation) {
        let store = context.store
        let novel = context.novel
        await observer.run { store.observe(NovelOverview.self, novel) }
      }
      .task(id: checklist.generation) { await checklist.observe() }
      .novelExporter(exporter)
  }

  @ViewBuilder
  private var content: some View {
    switch observer.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("This novel could not be read", tableName: "Library"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Library")
        }
      }
      .fillingSurface()
    case .loaded(let overview):
      loaded(overview)
    }
  }

  @ViewBuilder
  private func loaded(_ overview: NovelOverview) -> some View {
    switch overview.presence {
    case .missing:
      ShadowContentUnavailable(
        Text("Novel not found", tableName: "Library"), systemImage: "book.closed", message: Text("It may have been removed on another device.", tableName: "Library")
      )
      .fillingSurface()
    case .unreadable:
      ShadowContentUnavailable(
        Text("This novel cannot be read", tableName: "Library"), systemImage: "lock",
        message: Text("It is stored in a form this version of Novel Forge does not understand.", tableName: "Library")
      )
      .fillingSurface()
    case .present(let novel):
      details(of: novel, overview: overview)
    }
  }

  private func details(of novel: NovelRecord, overview: NovelOverview) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space6) {
        header(novel)
        if novel.archived { archivedBanner(novel) }
        ChecklistCardView(model: checklist)
        chapterStats(overview.chapters)
        storyStats(overview)
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 960, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.root)
    .toolbar { ToolbarItemGroup { NovelActions(library: library, novel: novel, placement: .toolbar).shadowBarItem() } }
    .toolbar { ToolbarItem { ExportMenu(model: exporter, title: novel.displayTitle).shadowBarItem() } }
  }

  private func header(_ novel: NovelRecord) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text(verbatim: novel.displayTitle).shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
      if novel.hasDistinctName {
        Text(verbatim: novel.name).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      }
      if let brief = novel.brief, !brief.isEmpty {
        Text(verbatim: brief).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
      }
    }
  }

  private func archivedBanner(_ novel: NovelRecord) -> some View {
    ShadowCallout(Text("This novel is archived", tableName: "Library"), intent: .info, systemImage: "archivebox") {
      Button {
        Task { await library.restore(novel.id) }
      } label: {
        Text("Restore", tableName: "Library")
      }
    }
  }

  private func chapterStats(_ chapters: Derived<ChapterTally>) -> some View {
    section(Text("Chapters", tableName: "Library")) {
      StatTile(
        Text("Chapters final", tableName: "Library"), chapters, opens: .reader, value: { Text(verbatim: "\($0.finals) / \($0.known)") },
        caption: { _ in Text("Final of those planned or written", tableName: "Library") })
      StatTile(
        Text("Drafted", tableName: "Library"), chapters, opens: .reader, value: { Text(verbatim: "\($0.drafted)") },
        caption: { _ in Text("Chapters with a draft", tableName: "Library") })
      StatTile(
        Text("Approved", tableName: "Library"), chapters, opens: .reader, value: { Text(verbatim: "\($0.approved)") },
        caption: { _ in Text("Ready to finalize", tableName: "Library") })
      StatTile(
        Text("Stale", tableName: "Library"), chapters, opens: .reader, value: { Text(verbatim: "\($0.stale)") },
        caption: { $0.stale > 0 ? Text("Need attention", tableName: "Library") : Text("All up to date", tableName: "Library") })
      StatTile(
        Text("Next chapter", tableName: "Library"), chapters, opens: .reader, deepLink: { .route(.reader, ReaderRoute.chapter($0.next)) }, value: { Text(verbatim: "\($0.next)") },
        caption: { _ in Text("To write next", tableName: "Library") })
    }
  }

  private func storyStats(_ overview: NovelOverview) -> some View {
    section(Text("Story", tableName: "Library")) {
      StatTile(
        Text("Active volume", tableName: "Library"), overview.activeVolume, opens: .story,
        deepLink: { $0.map { .route(.story, StoryRoute.volume($0.volume)) } },
        value: { $0.map { Text(verbatim: $0.title ?? $0.volume) } ?? Text("None", tableName: "Library") },
        caption: { $0 == nil ? Text("No volume is active", tableName: "Library") : Text("In progress", tableName: "Library") })
      StatTile(
        Text("Milestones", tableName: "Library"), overview.milestones, opens: .story, value: { Text(verbatim: "\($0.reached) / \($0.open + $0.planned + $0.reached)") },
        caption: { Text("\($0.open) open, \($0.planned) planned", tableName: "Library") })
      StatTile(
        Text("Story Bible", tableName: "Library"), overview.bible, opens: .storyBible, value: { Text("\($0.pages) pages", tableName: "Library") },
        caption: { Text("\($0.entities) entities", tableName: "Library") })
      StatTile(
        Text("Notebook", tableName: "Library"), overview.notebookEntries, opens: .notebook, value: { Text(verbatim: "\($0)") },
        caption: { _ in Text("Active entries", tableName: "Library") })
    }
  }

  private func section<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      title.shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
      ShadowStatisticGrid(minimumWidth: 160) { content() }
    }
  }
}
