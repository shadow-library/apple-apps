// Generated from Design/tokens.json by Scripts/generate-design-tokens.swift. Do not edit; run `mise run tokens`.

import CoreGraphics

nonisolated public enum Radius {
  /// Mac checkboxes, small tags, keyboard-shortcut keycaps.
  public static let sm: CGFloat = 4

  /// Mac buttons, fields and segmented controls (Shadow default control radius).
  public static let md: CGFloat = 6

  /// Mac cards, popovers, menus; iOS small tiles and avatars in squircle mode.
  public static let lg: CGFloat = 8

  /// iOS text fields, search fields and stepper; Mac sheets, alerts and the command palette.
  public static let xl: CGFloat = 12

  /// Mac windows' content cards and inspector panels; iOS menus and popovers.
  public static let xxl: CGFloat = 16

  /// Apple addition: iOS and iPadOS inset grouped list sections and content cards.
  public static let section: CGFloat = 20

  /// Apple addition: glass panels on iPhone and iPad (menus, popovers, the command palette), concentric with their 44pt rows.
  public static let panel: CGFloat = 26

  /// Apple addition: iPhone and iPad sheets and alerts, concentric with the device corner.
  public static let sheet: CGFloat = 32

  /// Capsules: every iOS and iPadOS button, tags, badges, switches, the tab bar, toolbar groups.
  public static let full: CGFloat = 9999

  public static let tokens: [ShadowScalarToken] = [
    ShadowScalarToken(name: "radius-sm", value: sm),
    ShadowScalarToken(name: "radius-md", value: md),
    ShadowScalarToken(name: "radius-lg", value: lg),
    ShadowScalarToken(name: "radius-xl", value: xl),
    ShadowScalarToken(name: "radius-2xl", value: xxl),
    ShadowScalarToken(name: "radius-section", value: section),
    ShadowScalarToken(name: "radius-panel", value: panel),
    ShadowScalarToken(name: "radius-sheet", value: sheet),
    ShadowScalarToken(name: "radius-full", value: full),
  ]
}
