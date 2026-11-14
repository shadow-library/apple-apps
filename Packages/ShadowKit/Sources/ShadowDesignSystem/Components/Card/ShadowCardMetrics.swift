import SwiftUI

nonisolated public struct ShadowCardMetrics: Hashable, Sendable {
  public let cornerRadius: CGFloat
  public let horizontalPadding: CGFloat
  public let verticalPadding: CGFloat
  public let spacing: CGFloat
  public let borderWidth: CGFloat

  public init(density: ShadowDensity = .current) {
    switch density {
    case .touch:
      cornerRadius = Radius.section
      horizontalPadding = Spacing.space4
      verticalPadding = Spacing.space4
      borderWidth = 0
    case .compact:
      cornerRadius = Radius.lg
      horizontalPadding = Spacing.space4
      verticalPadding = Spacing.space3
      borderWidth = 1
    }
    spacing = Spacing.space3
  }

  public var padding: EdgeInsets {
    EdgeInsets(top: verticalPadding, leading: horizontalPadding, bottom: verticalPadding, trailing: horizontalPadding)
  }

  public var innerCornerRadius: CGFloat {
    max(cornerRadius - min(horizontalPadding, verticalPadding), Radius.sm)
  }
}
