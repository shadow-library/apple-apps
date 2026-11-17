import ShadowDesignSystem
import SwiftUI

struct ProseView: View {
  let markdown: String
  private let blocks: [ProseBlock]

  init(markdown: String) {
    self.markdown = markdown
    blocks = ProseBlocks.parse(markdown)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func view(for block: ProseBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      Text(ProseBlocks.attributed(text)).shadowFont(level == 1 ? .title2 : level == 2 ? .title3 : .headline).foregroundStyle(ShadowColor.textPrimary)
    case .paragraph(let text):
      Text(ProseBlocks.attributed(text)).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).lineSpacing(Spacing.space1)
    case .quote(let text):
      Text(ProseBlocks.attributed(text)).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary).padding(.leading, Spacing.space4)
        .overlay(alignment: .leading) { Rectangle().fill(ShadowColor.borderDefault).frame(width: 2) }
    case .list(let items):
      VStack(alignment: .leading, spacing: Spacing.space1) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Text(verbatim: "•")
            Text(ProseBlocks.attributed(item))
          }
          .shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
        }
      }
    case .rule:
      Text(verbatim: "* * *").shadowFont(.body).foregroundStyle(ShadowColor.textTertiary).frame(maxWidth: .infinity)
    }
  }
}
