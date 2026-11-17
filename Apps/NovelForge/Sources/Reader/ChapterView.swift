import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct ChapterView: View {
  let context: NovelContext
  let chapter: Int
  @Environment(ReaderModel.self) private var model
  @State private var observer = ReadObserver<ChapterContent>()
  @State private var generation = 0
  @State private var editing = false
  @State private var importing = false
  @State private var openedEmptyDraft = false

  var body: some View {
    content
      .navigationTitle(ChapterDisplay.heading(chapter))
      .task(id: generation) {
        let store = context.store
        let locator = ChapterLocator(novel: context.novel, chapter: chapter)
        await observer.run { store.observe(ChapterContent.self, locator) }
      }
      .onChange(of: observer.state) {
        sync()
        openEmptyDraft()
      }
      .onDisappear { leave() }
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

  @ViewBuilder
  private var content: some View {
    switch observer.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("This chapter could not be read", tableName: "Reader"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Reader")
        }
      }
      .fillingSurface()
    case .loaded(let loaded):
      page(loaded)
    }
  }

  @ViewBuilder
  private func page(_ loaded: ChapterContent) -> some View {
    if let editor = model.existingEditor(for: chapter), editing || editor.isBlocked, editor.needsAttention {
      editorPage(loaded, editor: editor)
    } else {
      pageBody(of: loaded)
    }
  }

  @ViewBuilder
  private func pageBody(of loaded: ChapterContent) -> some View {
    switch loaded.body {
    case .missing:
      missingPage(loaded)
    case .unreadable:
      ShadowContentUnavailable(
        Text("This chapter cannot be read", tableName: "Reader"), systemImage: "lock",
        message: Text("It is stored in a form this version of Novel Forge does not understand.", tableName: "Reader")
      )
      .fillingSurface()
    case .final(let final):
      reading(loaded, title: final.title, markdown: final.body, note: final.note, amended: final.amended)
    case .draft(let draft):
      draftPage(loaded, draft: draft)
    }
  }

  private func missingPage(_ loaded: ChapterContent) -> some View {
    ScrollView {
      VStack(spacing: Spacing.space6) {
        ShadowContentUnavailable(
          Text("Chapter not found", tableName: "Reader"), systemImage: "text.book.closed",
          message: loaded.row == nil
            ? Text("It may have been removed on another device.", tableName: "Reader")
            : Text("It has no draft yet. Start the next chapter from the chapter list.", tableName: "Reader")
        )
        keptCallout(loaded)
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
    }
    .shadowScreen(.pushed)
  }

  @ViewBuilder
  private func keptCallout(_ loaded: ChapterContent) -> some View {
    if let kept = loaded.kept {
      KeptTextCallout(kept: kept) { await model.discardKept(in: chapter) }
    }
  }

  @ViewBuilder
  private func draftPage(_ loaded: ChapterContent, draft: ChapterContent.Draft) -> some View {
    if editing, let editor = model.existingEditor(for: chapter) {
      editorPage(loaded, editor: editor)
    } else {
      let text = model.existingEditor(for: chapter)?.text ?? draft.editable
      reading(loaded, title: text.title, markdown: text.body, note: nil, amended: false)
        .toolbar { readingToolbar(draft) }
    }
  }

  private func reading(_ loaded: ChapterContent, title: String?, markdown: String, note: String?, amended: Bool) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space6) {
        header(loaded, title: title, amended: amended)
        stateCallouts(loaded)
        keptCallout(loaded)
        ProseView(markdown: markdown)
        if let note = ChapterDisplay.title(note) {
          ShadowCallout(Text("Author's note", tableName: "Reader"), message: Text(verbatim: note), intent: .info) { EmptyView() }
        }
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.pushed)
  }

  private func header(_ loaded: ChapterContent, title: String?, amended: Bool) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space3) {
        ChapterDisplay.heading(chapter).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        if let row = loaded.row {
          let stage = ChapterDisplay.stage(of: row)
          Label(title: { stage.label }, icon: { Image(systemName: stage.systemImage) }).shadowFont(.caption).foregroundStyle(stage.color)
        }
        if amended { Text("Amended", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary) }
      }
      if let title = ChapterDisplay.title(title) {
        Text(verbatim: title).shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary)
      } else {
        Text("Untitled chapter", tableName: "Reader").shadowFont(.largeTitle).foregroundStyle(ShadowColor.textTertiary)
      }
    }
  }

  @ViewBuilder
  private func stateCallouts(_ loaded: ChapterContent) -> some View {
    if let row = loaded.row, row.stage != .final, let stale = row.stale {
      ShadowCallout(Text("This draft is stale", tableName: "Reader"), message: ChapterDisplay.staleReason(stale), intent: .warning) { EmptyView() }
    }
    if loaded.row?.hasUnreadableCanon == true {
      ShadowCallout(Text("Its final text cannot be read by this version", tableName: "Reader"), intent: .warning) { EmptyView() }
    }
  }

  private func editorPage(_ loaded: ChapterContent, editor: ChapterEditorModel) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        ChapterDisplay.heading(chapter).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        stateCallouts(loaded)
        ChapterEditorView(editor: editor) { leaveEditor(editor) }
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.pushed)
    .toolbar {
      ToolbarItemGroup {
        Button {
          Task { await editor.save() }
        } label: {
          Label(title: { Text("Save", tableName: "Reader") }, icon: { Image(systemName: "checkmark") })
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!editor.canSave || !editor.isDirty)
        .shadowBarItem()
        Button {
          Task {
            guard await editor.finish() else { return }
            editing = false
            model.release(chapter)
          }
        } label: {
          Text("Done", tableName: "Reader")
        }
        .disabled(!editor.canSave)
        .shadowBarItem()
      }
    }
  }

  @ToolbarContentBuilder
  private func readingToolbar(_ draft: ChapterContent.Draft) -> some ToolbarContent {
    ToolbarItemGroup {
      Button {
        _ = model.editor(for: chapter, draft: draft)
        editing = true
      } label: {
        Label(title: { Text("Edit", tableName: "Reader") }, icon: { Image(systemName: "pencil") })
      }
      .shadowBarItem()
      NavigationLink(value: ReaderRoute.versions(chapter)) {
        Label(title: { Text("Versions", tableName: "Reader") }, icon: { Image(systemName: "clock.arrow.circlepath") })
      }
      .shadowBarItem()
      Button {
        importing = true
      } label: {
        Label(title: { Text("Import Draft…", tableName: "Reader") }, icon: { Image(systemName: "square.and.arrow.down") })
      }
      .shadowBarItem()
    }
  }

  private func leaveEditor(_ editor: ChapterEditorModel) {
    Task {
      await editor.flush()
      editor.leave()
      editing = false
      model.release(chapter)
    }
  }

  private func sync() {
    guard let loaded = observer.state.value, let editor = model.existingEditor(for: chapter) else { return }
    switch loaded.body {
    case .draft(let draft): editor.reconcile(with: draft)
    case .final: editor.reconcileFinal()
    case .missing: editor.reconcileMissing()
    case .unreadable: break
    }
  }

  private func leave() {
    guard let editor = model.existingEditor(for: chapter) else { return }
    let model = model
    let chapter = chapter
    Task {
      _ = await editor.finish()
      model.release(chapter)
    }
  }

  private func openEmptyDraft() {
    guard !editing, !openedEmptyDraft, let loaded = observer.state.value, case .draft(let draft) = loaded.body, draft.editable.body.allSatisfy(\.isWhitespace) else { return }
    _ = model.editor(for: chapter, draft: draft)
    openedEmptyDraft = true
    editing = true
  }

  private func importFile(_ result: Result<URL, any Error>) async {
    switch result {
    case .failure(let error):
      model.fail(error)
    case .success(let url):
      do {
        let prose = try await Task.detached { try DraftFile.read(from: url) }.value
        var revision: String?
        if case .draft(let draft)? = observer.state.value?.body { revision = draft.revision }
        _ = await model.importProse(prose, into: chapter, currentRevision: revision)
      } catch {
        model.failure = ActionFailure(error: DraftImportErrors.presented(error))
      }
    }
  }
}
