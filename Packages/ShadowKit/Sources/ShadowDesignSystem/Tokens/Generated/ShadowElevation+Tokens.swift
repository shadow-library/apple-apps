// Generated from Design/tokens.json by Scripts/generate-design-tokens.swift. Do not edit; run `mise run tokens`.

import CoreGraphics

nonisolated extension ShadowElevation {
  /// Segmented thumb, switch knob, slider thumb. Dark mode: none, the surface is lifted instead.
  public static let e1 = ShadowElevation(
    light: [
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.06), x: 0, y: 1, blur: 2, spread: 0),
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.1), x: 0, y: 1, blur: 3, spread: 0),
    ],
    dark: []
  )

  /// Menus and context menus.
  public static let e2 = ShadowElevation(
    light: [
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.1), x: 0, y: 4, blur: 8, spread: -2),
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.06), x: 0, y: 2, blur: 4, spread: -2),
    ],
    dark: []
  )

  /// Popovers, alerts, Mac sheets and the command palette.
  public static let e3 = ShadowElevation(
    light: [
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.12), x: 0, y: 12, blur: 24, spread: -6),
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.08), x: 0, y: 4, blur: 8, spread: -4),
    ],
    dark: []
  )

  /// Every floating glass shape. Apple addition: glass keeps its shadow in dark mode so it separates from content.
  public static let glass = ShadowElevation(
    light: [
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.22), x: 0, y: 8, blur: 28, spread: -10),
      Layer(color: ShadowRGBA(hex: 0x09090B, alpha: 0.06), x: 0, y: 1, blur: 3, spread: 0),
    ],
    dark: [
      Layer(color: ShadowRGBA(hex: 0x000000, alpha: 0.7), x: 0, y: 10, blur: 30, spread: -10)
    ]
  )
}
