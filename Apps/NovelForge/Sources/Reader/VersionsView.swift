import NovelForgeCore
import ShadowCore
import ShadowDesignSystem
import SwiftUI

struct VersionsView: View {
  let context: NovelContext
  let chapter: Int
  @Environment(ReaderModel.self) private var model
  @Environment(NovelNavigator.self) private var navigator
  @State private var observer = ReadObserver<ChapterVersions>()
  @State private var generation = 0
  @State private var restoring: VersionEntry?
  @State private var isRestoring = false
  @State private var currentRevision: String?

  var body: some View {
    content
      .navigationTitle(Text("Versions of Chapter \(chapter)", tableName: "Reader"))
      .task(id: generation) {
        let store = context.store
        let locator = ChapterLocator(novel: context.novel, chapter: chapter)
        await observer.run { store.observe(ChapterVersions.self, locator) }
      }
      .confirmationDialog(
        Text("Restore this version?", tableName: "Reader"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible,
        presenting: restoring
      ) { entry in
        Button {
          Task { await restore(entry) }
        } label: {
          Text("Restore", tableName: "Reader")
        }
        Button(role: .cancel) {
        } label: {
          Text("Cancel", tableName: "Reader")
        }
      } message: { _ in
        Text("Your current text is kept as a version. The restored text needs approving again.", tableName: "Reader")
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
      ShadowContentUnavailable(Text("The versions could not be read", tableName: "Reader"), systemImage: "exclamationmark.triangle", message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "Reader")
        }
      }
      .fillingSurface()
    case .loaded(let loaded):
      switch loaded.state {
      case .missing:
        ShadowContentUnavailable(
          Text("Chapter not found", tableName: "Reader"), systemImage: "text.book.closed", message: Text("It has no draft, so there are no versions.", tableName: "Reader")
        )
        .fillingSurface()
      case .final:
        ShadowContentUnavailable(
          Text("This chapter is final", tableName: "Reader"), systemImage: "checkmark.seal", message: Text("A final chapter keeps no draft versions.", tableName: "Reader")
        )
        .fillingSurface()
      case .listed(let entries, let kept):
        list(entries, kept: kept)
      }
    }
  }

  private func list(_ entries: [VersionEntry], kept: ChapterText?) -> some View {
    List {
      if let kept { keptRow(kept) }
      ForEach(entries) { entry in
        row(entry, current: entries.first { $0.version.isCurrent }?.version.revision)
      }
    }
    .listStyle(.inset)
    .shadowScreen(.pushed)
  }

  private func keptRow(_ kept: ChapterText) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space3) {
        Text("Kept on this device (not synced)", tableName: "Reader").shadowFont(.headline).foregroundStyle(ShadowColor.warningText)
        Spacer()
        Text("\(WordCount.words(in: kept.body)) words", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).monospacedDigit()
      }
      Text(verbatim: kept.body.split(whereSeparator: \.isWhitespace).prefix(40).joined(separator: " ")).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).lineLimit(
        3)
    }
    .padding(.vertical, Spacing.space1)
  }

  private func row(_ entry: VersionEntry, current: String?) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space3) {
        Text(entry.version.created.date, format: .dateTime.day().month().year().hour().minute()).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        ChapterDisplay.source(entry.version.source?.known).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        if entry.version.isCurrent { Text("Current", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.accent) }
        if entry.version.isApproved { Text("Approved", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.successText) }
        Spacer()
        Text("\(entry.words) words", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).monospacedDigit()
        if !entry.version.isCurrent, let current {
          Button {
            restoring = entry
            currentRevision = current
          } label: {
            Text("Restore", tableName: "Reader")
          }
          .disabled(isRestoring)
        }
      }
      if let title = ChapterDisplay.title(entry.title) { Text(verbatim: title).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary) }
      if !entry.excerpt.isEmpty {
        Text(verbatim: entry.excerpt).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).lineLimit(3)
      }
    }
    .padding(.vertical, Spacing.space1)
  }

  private func restore(_ entry: VersionEntry) async {
    guard let currentRevision else { return }
    isRestoring = true
    defer { isRestoring = false }
    guard await model.restore(revision: entry.version.revision, in: chapter, current: currentRevision) else { return }
    navigator.pop(.reader)
  }
}
