import NovelForgeCore
import ShadowDesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct ReaderView: View {
  let context: NovelContext
  @Environment(NovelNavigator.self) private var navigator
  let model: ReaderModel
  @State private var observer = ReadObserver<ChapterOutline>()
  @State private var generation = 0
  @State private var collapsed = Set<String>()
  @State private var seen = Set<String>()
  @State private var importing = false

  var body: some View {
    content
      .navigationTitle(Text(NovelSection.reader.title))
      .navigationDestination(for: ReaderRoute.self) { route in
        ReaderDestination(route: route, context: context, model: model)
      }
      .environment(model)
      .task(id: ObservationKey(generation: generation, isVisible: isAtRoot)) {
        guard isAtRoot else { return }
        let store = context.store
        let novel = context.novel
        await observer.run { store.observe(ChapterOutline.self, novel) }
      }
      .toolbar { toolbar }
      .onChange(of: observer.state, initial: true) { collapseGoalMetVolumes() }
      .fileImporter(isPresented: $importing, allowedContentTypes: DraftImportTypes.allowed) { result in
        Task { await importFile(result) }
      }
      .alert(
        Text(verbatim: model.failure?.error.headline ?? ""), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
      ) {
        Button {
          model.failure = nil
        } label: {
          Text("OK", tableName: "Reader")
        }
      }
  }

  private var isAtRoot: Bool {
    navigator.paths[.reader]?.isEmpty ?? true
  }

  @ViewBuilder
  private var content: some View {
    switch observer.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("The chapters could not be read", tableName: "Reader"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Reader")
        }
      }
      .fillingSurface()
    case .loaded(let outline):
      loaded(outline)
    }
  }

  @ViewBuilder
  private func loaded(_ outline: ChapterOutline) -> some View {
    switch outline.presence {
    case .missing:
      ShadowContentUnavailable(
        Text("Novel not found", tableName: "Reader"), systemImage: "book.closed", message: Text("It may have been removed on another device.", tableName: "Reader")
      )
      .fillingSurface()
    case .unreadable:
      ShadowContentUnavailable(
        Text("This novel cannot be read", tableName: "Reader"), systemImage: "lock",
        message: Text("It is stored in a form this version of Novel Forge does not understand.", tableName: "Reader")
      )
      .fillingSurface()
    case .present:
      chapters(outline)
    }
  }

  @ViewBuilder
  private func chapters(_ outline: ChapterOutline) -> some View {
    switch outline.rows {
    case .unavailable(let faults):
      ShadowContentUnavailable(
        Text("Chapters are unavailable", tableName: "Reader"), systemImage: "exclamationmark.triangle",
        message: Text("They are not up to date on this device yet.", tableName: "Reader")
      ) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Reader")
        }
      }
      .help(Text(verbatim: faults.first?.message ?? ""))
      .fillingSurface()
    case .available(let rows):
      list(outline, rows: rows)
    }
  }

  private func list(_ outline: ChapterOutline, rows: [ChapterRow]) -> some View {
    let byChapter = Dictionary(rows.map { ($0.chapter, $0) }) { first, _ in first }
    let cursor = outline.next.value
    let writable = outline.nextWritable ?? 1
    return List {
      if outline.headings.isUnavailable {
        ShadowCallout(
          Text("Titles and volumes are unavailable", tableName: "Reader"), message: Text("Chapters are listed by number, without their titles or volumes.", tableName: "Reader"),
          intent: .warning
        ) {
          EmptyView()
        }
      } else if outline.volumes.isUnavailable {
        ShadowCallout(Text("Volumes are unavailable", tableName: "Reader"), message: Text("Chapters are listed without their volumes.", tableName: "Reader"), intent: .warning) {
          EmptyView()
        }
      }
      ForEach(outline.groups, id: \.key) { group in
        groupSection(group, outline: outline, rows: byChapter, cursor: cursor)
      }
      if byChapter[writable] == nil { startRow(next: writable) }
    }
    .listStyle(.inset)
    .shadowScreen(.root)
    .overlay {
      if rows.isEmpty { emptyState(next: writable) }
    }
  }

  private func groupSection(_ group: ChapterGroup, outline: ChapterOutline, rows: [Int: ChapterRow], cursor: Int?) -> some View {
    Section {
      if !collapsed.contains(group.key) {
        ForEach(group.chapters, id: \.self) { chapter in
          if let row = rows[chapter] { chapterLink(row, heading: outline.headings.value?[chapter], isCursor: chapter == cursor) }
        }
      }
    } header: {
      groupHeader(group)
    }
  }

  @ViewBuilder
  private func groupHeader(_ group: ChapterGroup) -> some View {
    if let volume = group.volume, let number = group.number {
      Button {
        if !collapsed.insert(group.key).inserted { collapsed.remove(group.key) }
      } label: {
        HStack(spacing: Spacing.space2) {
          Image(systemName: collapsed.contains(group.key) ? "chevron.right" : "chevron.down").shadowFont(.caption).frame(width: Spacing.space4)
          Text("Volume \(number)", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          Text(verbatim: ChapterDisplay.title(volume.title) ?? "").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          Spacer(minLength: Spacing.space2)
          volumeState(volume.state)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(.isHeader)
    }
  }

  private func volumeState(_ state: VolumeState) -> some View {
    switch state {
    case .active: Text("Active", tableName: "Reader").foregroundStyle(ShadowColor.accent).shadowFont(.caption)
    case .goalMet: Text("Goal met", tableName: "Reader").foregroundStyle(ShadowColor.successText).shadowFont(.caption)
    case .notStarted: Text("Not started", tableName: "Reader").foregroundStyle(ShadowColor.textSecondary).shadowFont(.caption)
    }
  }

  private func chapterLink(_ row: ChapterRow, heading: String?, isCursor: Bool) -> some View {
    NavigationLink(value: ReaderRoute.chapter(row.chapter)) {
      ChapterRowView(row: row, heading: heading, isCursor: isCursor, hasUnsavedWork: model.hasUnsavedWork(in: row.chapter))
    }
  }

  private func startRow(next: Int) -> some View {
    HStack {
      Text("Chapter \(next) is next", tableName: "Reader").foregroundStyle(ShadowColor.textSecondary)
      Spacer()
      Button {
        Task { await startNext() }
      } label: {
        Text("Start Chapter \(next)", tableName: "Reader")
      }
      .disabled(model.isStarting)
    }
  }

  private func emptyState(next: Int) -> some View {
    ShadowContentUnavailable(
      Text("No chapters yet", tableName: "Reader"), systemImage: "text.book.closed",
      message: Text("Start the first chapter by hand, or import a draft from a text or Markdown file.", tableName: "Reader")
    ) {
      HStack {
        Button {
          Task { await startNext() }
        } label: {
          Text("Start Chapter \(next)", tableName: "Reader")
        }
        .disabled(model.isStarting)
        Button {
          importing = true
        } label: {
          Text("Import Draft…", tableName: "Reader")
        }
      }
    }
    .fillingSurface()
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup {
      Button {
        Task { await startNext() }
      } label: {
        Label(title: { Text("Start Next Chapter", tableName: "Reader") }, icon: { Image(systemName: "square.and.pencil") })
      }
      .disabled(model.isStarting || observer.state.value?.nextWritable == nil)
      .shadowBarItem()
      Button {
        importing = true
      } label: {
        Label(title: { Text("Import Draft…", tableName: "Reader") }, icon: { Image(systemName: "square.and.arrow.down") })
      }
      .disabled(observer.state.value?.nextWritable == nil)
      .shadowBarItem()
    }
  }

  private func collapseGoalMetVolumes() {
    guard let outline = observer.state.value else { return }
    for group in outline.groups where seen.insert(group.key).inserted {
      if group.volume?.state == .goalMet { collapsed.insert(group.key) }
    }
  }

  private func startNext() async {
    guard let chapter = await model.startNext() else { return }
    navigator.push(ReaderRoute.chapter(chapter))
  }

  private func importFile(_ result: Result<URL, any Error>) async {
    guard let next = observer.state.value?.nextWritable, case .success(let url) = result else {
      if case .failure(let error) = result { model.fail(error) }
      return
    }
    do {
      let prose = try await Task.detached { try DraftFile.read(from: url) }.value
      guard await model.importProse(prose, into: next) else { return }
      navigator.push(ReaderRoute.chapter(next))
    } catch {
      model.failure = ActionFailure(error: DraftImportErrors.presented(error))
    }
  }
}

private struct ObservationKey: Hashable {
  let generation: Int
  let isVisible: Bool
}

enum DraftImportTypes {
  static var allowed: [UTType] {
    [.plainText, UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
  }
}
