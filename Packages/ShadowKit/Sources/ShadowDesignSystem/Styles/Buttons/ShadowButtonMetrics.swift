import SwiftUI

nonisolated public enum ShadowButtonLayout: Hashable, Sendable, CaseIterable {
  case text
  case icon
}

nonisolated public struct ShadowButtonMetrics: Hashable, Sendable {
  public let visualHeight: CGFloat
  public let visualWidth: CGFloat?
  public let horizontalPadding: CGFloat
  public let verticalPadding: CGFloat
  public let cornerRadius: CGFloat
  public let hitSize: CGFloat
  let labelStyle: Font.TextStyle
  let labelWeight: Font.Weight

  public init(density: ShadowDensity = .current, size: ShadowControlSize, layout: ShadowButtonLayout = .text, isGlass: Bool = false) {
    let height = density.controlHeight(size)
    visualHeight = height
    visualWidth = layout == .icon ? height : nil
    horizontalPadding = layout == .icon ? 0 : Self.horizontalPadding(density: density, size: size)
    verticalPadding = density == .touch ? Spacing.space2 : Spacing.space1
    cornerRadius = density == .touch || isGlass ? height / 2 : Radius.md
    hitSize = density == .touch ? ShadowMetrics.tapTarget : 0
    (labelStyle, labelWeight) = Self.label(density: density, size: size, layout: layout)
  }

  public var layoutHeight: CGFloat { max(visualHeight, hitSize) }

  var labelFont: Font { .system(labelStyle, weight: labelWeight) }

  private static func horizontalPadding(density: ShadowDensity, size: ShadowControlSize) -> CGFloat {
    switch (density, size) {
    case (.touch, .small): Spacing.space4
    case (.touch, .medium): Spacing.space5
    case (.touch, .large): Spacing.space6
    case (.compact, .small): Spacing.space2
    case (.compact, .medium), (.compact, .large): Spacing.space3
    }
  }

  private static func label(density: ShadowDensity, size: ShadowControlSize, layout: ShadowButtonLayout) -> (Font.TextStyle, Font.Weight) {
    switch (density, size, layout) {
    case (.touch, .small, .text): (.subheadline, .semibold)
    case (.touch, _, .text): (.headline, .semibold)
    case (.touch, .small, .icon): (.body, .regular)
    case (.touch, .medium, .icon): (.title3, .regular)
    case (.touch, .large, .icon): (.title2, .regular)
    case (.compact, .small, .text): (.callout, .medium)
    case (.compact, _, .text): (.body, .medium)
    case (.compact, .small, .icon): (.body, .regular)
    case (.compact, .medium, .icon): (.title3, .regular)
    case (.compact, .large, .icon): (.title2, .regular)
    }
  }
}
