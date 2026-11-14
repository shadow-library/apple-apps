import SwiftUI

nonisolated public struct ShadowTagMetrics: Hashable, Sendable {
  public let height: CGFloat
  public let hitOutset: CGFloat
  public let leadingPadding: CGFloat
  public let trailingPadding: CGFloat
  public let spacing: CGFloat
  let style: ShadowTextStyle

  public init(density: ShadowDensity = .current, size: ShadowControlSize) {
    let isSmall = size == .small
    switch density {
    case .touch:
      height = isSmall ? ShadowMetrics.controlTouchSm - Spacing.space2 : ShadowMetrics.controlTouchSm
      hitOutset = (ShadowMetrics.tapTarget - height) / 2
      leadingPadding = isSmall ? Spacing.space2 : Spacing.space3
      trailingPadding = leadingPadding
      spacing = Spacing.space1 + Spacing.space05
      style = isSmall ? .iosFootnote : .iosSubheadline
    case .compact:
      height = isSmall ? Spacing.space4 + Spacing.space05 : Spacing.space5 + Spacing.space05
      hitOutset = 0
      leadingPadding = isSmall ? Spacing.space1 + Spacing.space05 : Spacing.space2
      trailingPadding = leadingPadding
      spacing = Spacing.space1 + Spacing.space05
      style = isSmall ? .macCallout : .macBody
    }
  }
}
