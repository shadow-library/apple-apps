import SwiftUI

nonisolated struct ShadowButtonPalette: Equatable {
  let fill: Color?
  let border: Color?
  let foreground: Color

  init(
    appearance: ShadowButtonAppearance,
    isDestructive: Bool,
    interaction: ShadowButtonInteraction,
    increasedContrast: Bool = false,
    showsButtonShapes: Bool = false,
    glassForeground: Color = ShadowColor.textPrimary
  ) {
    switch appearance {
    case .filled:
      fill = isDestructive ? Self.dangerSolid(interaction) : Self.accent(interaction)
      border = nil
      foreground = isDestructive ? ShadowColor.dangerOnSolid : ShadowColor.onAccent
    case .tinted:
      fill = Self.tinted(isDestructive: isDestructive, interaction: interaction)
      border = nil
      foreground = isDestructive ? ShadowColor.dangerTextOnSubtle : ShadowColor.accentText
    case .bordered:
      fill = Self.bordered(interaction)
      border = interaction == .idle && !increasedContrast ? ShadowColor.borderDefault : ShadowColor.borderStrong
      foreground = isDestructive ? ShadowColor.destructiveLabel : ShadowColor.textPrimary
    case .plain, .barItem:
      fill = Self.plain(interaction, showsButtonShapes: showsButtonShapes)
      border = nil
      foreground = Self.plainForeground(appearance: appearance, isDestructive: isDestructive, glassForeground: glassForeground)
    case .glass:
      fill = nil
      border = nil
      foreground = isDestructive ? ShadowColor.destructiveLabel : ShadowColor.textPrimary
    case .glassProminent:
      fill = nil
      border = nil
      foreground = isDestructive ? ShadowColor.destructiveLabel : ShadowColor.onAccent
    }
  }

  private static func accent(_ interaction: ShadowButtonInteraction) -> Color {
    switch interaction {
    case .idle: ShadowColor.accent
    case .hovered: ShadowColor.accentHover
    case .pressed: ShadowColor.accentActive
    }
  }

  private static func dangerSolid(_ interaction: ShadowButtonInteraction) -> Color {
    switch interaction {
    case .idle: ShadowColor.dangerSolid
    case .hovered: ShadowColor.dangerSolidHover
    case .pressed: ShadowColor.dangerSolidActive
    }
  }

  private static func tinted(isDestructive: Bool, interaction: ShadowButtonInteraction) -> Color {
    let rest = isDestructive ? ShadowColor.dangerBgSubtle : ShadowColor.accentSoft
    let ink = isDestructive ? ShadowColor.dangerSolid : ShadowColor.accent
    switch interaction {
    case .idle: return rest
    case .hovered: return rest.mix(with: ink, by: 0.08)
    case .pressed: return rest.mix(with: ink, by: 0.16)
    }
  }

  private static func bordered(_ interaction: ShadowButtonInteraction) -> Color {
    switch interaction {
    case .idle: ShadowColor.surfaceCard
    case .hovered: ShadowColor.surfaceWell
    case .pressed: ShadowColor.bgPressed
    }
  }

  private static func plain(_ interaction: ShadowButtonInteraction, showsButtonShapes: Bool) -> Color? {
    switch interaction {
    case .idle: showsButtonShapes ? ShadowColor.surfaceWell : nil
    case .hovered: ShadowColor.bgHover
    case .pressed: ShadowColor.bgPressed
    }
  }

  private static func plainForeground(appearance: ShadowButtonAppearance, isDestructive: Bool, glassForeground: Color) -> Color {
    if isDestructive { return ShadowColor.destructiveLabel }
    return appearance == .barItem ? glassForeground : ShadowColor.accentText
  }
}
