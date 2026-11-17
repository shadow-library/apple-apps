import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct ChapterRowView: View {
  let row: ChapterRow
  let heading: String?
  let isCursor: Bool
  let hasUnsavedWork: Bool

  var body: some View {
    let stage = ChapterDisplay.stage(of: row)
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
      Text(verbatim: ChapterDisplay.number(row.chapter)).shadowFont(.monoBody).foregroundStyle(ShadowColor.textSecondary)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        titleText.shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).lineLimit(1)
        if isCursor { Text("The story continues here", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.accent) }
        if row.hasUnreadableCanon { Text("Its final text cannot be read by this version", tableName: "Reader").shadowFont(.caption).foregroundStyle(ShadowColor.warningText) }
      }
      Spacer(minLength: Spacing.space2)
      if hasUnsavedWork {
        Image(systemName: "pencil.circle.fill").foregroundStyle(ShadowColor.warningText).help(Text("Has changes that are not saved yet", tableName: "Reader")).accessibilityLabel(
          Text("Has changes that are not saved yet", tableName: "Reader"))
      }
      Label(title: { stage.label }, icon: { Image(systemName: stage.systemImage) }).shadowFont(.caption).foregroundStyle(stage.color)
    }
    .accessibilityElement(children: .combine)
  }

  private var titleText: Text {
    guard let title = ChapterDisplay.title(heading) else { return Text("Chapter \(row.chapter)", tableName: "Reader") }
    return Text(verbatim: title)
  }
}
