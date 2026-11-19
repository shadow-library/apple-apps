import NovelForgeCore
import ShadowCore
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chapter-workspace/CompareVersionsDialog.tsx:44-117: the older version reads first, removed text struck through and added text underlined.
struct CompareVersionsSheet: View {
  let context: NovelContext
  let chapter: Int
  let entries: [VersionEntry]
  @State private var older: String
  @State private var newer: String
  @Environment(\.dismiss) private var dismiss
  @State private var model: VersionCompareModel

  init(context: NovelContext, chapter: Int, entries: [VersionEntry], older: String, newer: String) {
    self.context = context
    self.chapter = chapter
    self.entries = entries
    _older = State(initialValue: older)
    _newer = State(initialValue: newer)
    _model = State(initialValue: VersionCompareModel(store: context.store, novel: context.novel, chapter: chapter))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      HStack(spacing: Spacing.space3) {
        picker(Text("From", tableName: "Generation"), selection: $older)
        Text("with", tableName: "Generation").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        picker(Text("With", tableName: "Generation"), selection: $newer)
      }
      result
    }
    .padding(Spacing.space6)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .shadowSheetHeader(
      Text("Compare Versions", tableName: "Generation"), subtitle: Text("Chapter \(chapter)", tableName: "Generation"),
      cancel: ShadowSheetCancel(Text("Done", tableName: "Generation"), systemImage: "checkmark") { dismiss() }
    )
    .shadowSheetStyle(.full)
    .task(id: [older, newer]) { await model.load(older: sorted.older, newer: sorted.newer) }
  }

  private var sorted: (older: String, newer: String) {
    let positions = [older, newer].map { revision in entries.firstIndex { $0.version.revision == revision } ?? 0 }
    return positions[0] >= positions[1] ? (older, newer) : (newer, older)
  }

  private func picker(_ label: Text, selection: Binding<String>) -> some View {
    Picker(selection: selection) {
      ForEach(entries) { entry in
        Text(verbatim: name(entry)).tag(entry.version.revision)
      }
    } label: {
      label
    }
    .labelsHidden()
  }

  private func name(_ entry: VersionEntry) -> String {
    let date = entry.version.created.date.formatted(.dateTime.day().month().hour().minute())
    guard entry.version.isCurrent else { return date }
    return String(localized: "\(date) (current)", table: "Generation")
  }

  @ViewBuilder
  private var result: some View {
    switch model.state {
    case .loading: ProgressView().frame(maxWidth: .infinity, minHeight: 160)
    case .unreadable:
      ShadowContentUnavailable(
        Text("These versions can't be read", tableName: "Generation"), systemImage: "exclamationmark.triangle",
        message: Text("One of them is stored in a form this version of Novel Forge doesn't understand.", tableName: "Generation"))
    case .same:
      ShadowContentUnavailable(
        Text("Pick two different versions", tableName: "Generation"), systemImage: "arrow.left.arrow.right",
        message: Text("A version is the same as itself.", tableName: "Generation"))
    case .ready(let diff): ready(diff)
    }
  }

  private func ready(_ diff: VersionDiff) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        if diff.isIdentical {
          Text("These versions have the same text.", tableName: "Generation").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        } else {
          Text("\(diff.wordsAdded) words added · \(diff.wordsRemoved) words removed", tableName: "Generation").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
          ForEach(Array(diff.rows.enumerated()), id: \.offset) { _, row in
            switch row {
            case .unchanged(let count): Text("\(count) unchanged paragraphs", tableName: "Generation").shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary)
            case .paragraph(let paragraph): Text(Self.attributed(paragraph)).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
            }
          }
        }
      }
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  static func attributed(_ paragraph: DiffParagraph) -> AttributedString {
    var result = AttributedString()
    for (index, piece) in paragraph.pieces.enumerated() {
      let next = index < paragraph.pieces.count - 1 ? paragraph.pieces[index + 1].text : nil
      let spaced = next.map { !piece.text.hasSuffix("\n") && !$0.hasPrefix("\n") } ?? false
      var text = AttributedString(piece.text + (spaced ? " " : ""))
      switch piece.op {
      case .equal: break
      case .insert:
        text.underlineStyle = .single
        text.foregroundColor = ShadowColor.successText
      case .delete:
        text.strikethroughStyle = .single
        text.foregroundColor = ShadowColor.dangerText
      }
      result += text
    }
    return result
  }
}
