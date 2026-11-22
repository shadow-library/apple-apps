import ShadowDesignSystem
import SwiftUI

struct AcknowledgementsView: View {
  let acknowledgements: Acknowledgements

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ForEach(Array(acknowledgements.blocks.enumerated()), id: \.offset) { _, block in
          BlockView(block: block)
        }
      }
      .textSelection(.enabled)
      .padding(Spacing.space4)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .shadowScreen(.pushed)
    .navigationTitle(Text("Acknowledgements", tableName: "About", bundle: .module))
  }
}

private struct BlockView: View {
  let block: Acknowledgements.Block

  var body: some View {
    switch block {
    case .heading(let level, let text):
      Text(inline(text)).shadowFont(level == 1 ? .title2 : .headline).padding(.top, level == 1 ? 0 : Spacing.space2).accessibilityAddTraits(.isHeader)
    case .item(let text):
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        Text(verbatim: "•").accessibilityHidden(true)
        Text(inline(text)).fixedSize(horizontal: false, vertical: true)
      }
      .shadowFont(.body)
    case .paragraph(let text):
      Text(inline(text)).shadowFont(.body).fixedSize(horizontal: false, vertical: true)
    case .preformatted(let text):
      Text(verbatim: text)
        .shadowFont(.monoBody)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
  }

  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
  }
}
