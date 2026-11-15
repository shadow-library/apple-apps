import ShadowDesignSystem
import SwiftUI

struct QuestCheckGlyph: View {
  let isDone: Bool

  var body: some View {
    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
      .shadowFont(.title3)
      .foregroundStyle(isDone ? ShadowColor.accent : ShadowColor.borderStrong)
      .accessibilityHidden(true)
  }
}
