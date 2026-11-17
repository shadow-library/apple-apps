import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct NovelRow: View {
  let entry: LibraryEntry

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space05) {
      Text(verbatim: entry.novel.displayTitle)
        .shadowFont(.body)
        .foregroundStyle(ShadowColor.textPrimary)
        .lineLimit(2)
      if entry.novel.hasDistinctName {
        Text(verbatim: entry.novel.name).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).lineLimit(1)
      }
      progress.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var progress: some View {
    switch entry.chapters {
    case .available(let tally): Text("Chapters \(tally.finals)/\(tally.known)", tableName: "Library")
    case .unavailable: Label(title: { Text("Progress unavailable", tableName: "Library") }, icon: { Image(systemName: "exclamationmark.triangle") })
    }
  }
}
