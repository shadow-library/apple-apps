import ShadowDesignSystem
import SwiftUI

struct BibleChip: View {
  enum Tone {
    case neutral
    case warning
  }

  let text: Text
  var tone = Tone.neutral

  var body: some View {
    text
      .shadowFont(.footnote)
      .foregroundStyle(tone == .warning ? ShadowColor.warningTextOnSubtle : ShadowColor.textSecondary)
      .padding(.horizontal, Spacing.space2)
      .padding(.vertical, Spacing.space05)
      .background(tone == .warning ? ShadowColor.warningBgSubtle : ShadowColor.surfaceWell, in: Capsule())
  }
}
