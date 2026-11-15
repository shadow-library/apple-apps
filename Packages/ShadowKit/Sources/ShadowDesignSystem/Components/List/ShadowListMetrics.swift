import SwiftUI

nonisolated public struct ShadowListMetrics: Hashable, Sendable {
  public let minimumRowHeight: CGFloat
  public let horizontalPadding: CGFloat
  public let verticalPadding: CGFloat
  public let leadingGap: CGFloat
  public let tileSize: CGFloat
  public let tileCornerRadius: CGFloat
  public let indentation: CGFloat
  public let textLineLimit = 2
  public let showsChevron: Bool

  public init(density: ShadowDensity = .current) {
    minimumRowHeight = density.rowHeight
    leadingGap = Spacing.space3
    indentation = 22
    switch density {
    case .touch:
      horizontalPadding = Spacing.space4
      verticalPadding = Spacing.space2 + Spacing.space05
      tileSize = 30
      tileCornerRadius = Radius.lg
      showsChevron = true
    case .compact:
      horizontalPadding = Spacing.space3
      verticalPadding = Spacing.space1 + Spacing.space05
      tileSize = 20
      tileCornerRadius = Radius.md
      showsChevron = false
    }
  }

  public var rowInsets: EdgeInsets {
    EdgeInsets(top: verticalPadding, leading: horizontalPadding, bottom: verticalPadding, trailing: horizontalPadding)
  }

  public func separatorInset(leadingWidth: CGFloat?) -> CGFloat {
    guard let leadingWidth else { return horizontalPadding }
    return horizontalPadding + leadingWidth + leadingGap
  }
}

nonisolated public enum ShadowListRowPhase: Hashable, Sendable {
  case standard
  case hovered
  case selected
  case selectedInactive
  case onProminentBackground

  init(isSelected: Bool, isHovered: Bool, appearsActive: Bool, isProminent: Bool, isInList: Bool, density: ShadowDensity) {
    if isProminent {
      self = .onProminentBackground
    } else if isSelected && isInList && density == .compact {
      self = .standard
    } else if isSelected {
      self = appearsActive ? .selected : .selectedInactive
    } else {
      self = isHovered ? .hovered : .standard
    }
  }

  var hasBackground: Bool { self == .hovered || self == .selected || self == .selectedInactive }
}

nonisolated public struct ShadowListRowPalette: Hashable, Sendable {
  public let background: ShadowColorToken
  public let title: ShadowColorToken
  public let secondary: ShadowColorToken
  public let accessory: ShadowColorToken

  public init(density: ShadowDensity, phase: ShadowListRowPhase, isDestructive: Bool = false) {
    let destructive: ShadowColorToken? = isDestructive ? .destructiveLabel : nil
    switch (density, phase) {
    case (_, .onProminentBackground):
      background = .selectionRow
      title = .onAccent
      secondary = .onAccent
      accessory = .onAccent
    case (.touch, .selected), (.touch, .selectedInactive):
      background = .accentSoft
      title = destructive ?? .accentText
      secondary = .textSecondary
      accessory = .accentText
    case (.compact, .selected):
      background = .selectionRow
      title = destructive ?? .onAccent
      secondary = .onAccent
      accessory = .onAccent
    case (.compact, .selectedInactive):
      background = .bgPressed
      title = destructive ?? .textPrimary
      secondary = .textSecondary
      accessory = .textTertiary
    case (_, .hovered):
      background = .bgHover
      title = destructive ?? .textPrimary
      secondary = .textSecondary
      accessory = .textTertiary
    case (_, .standard):
      background = .surfaceCard
      title = destructive ?? .textPrimary
      secondary = .textSecondary
      accessory = .textTertiary
    }
  }
}
