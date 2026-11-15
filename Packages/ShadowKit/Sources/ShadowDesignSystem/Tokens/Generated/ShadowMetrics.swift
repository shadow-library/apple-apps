// Generated from Design/tokens.json by Scripts/generate-design-tokens.swift. Do not edit; run `mise run tokens`.

import CoreGraphics

nonisolated public enum ShadowMetrics {
  /// Minimum hit area on iPhone and iPad. Smaller visuals extend an invisible hit area.
  public static let tapTarget: CGFloat = 44

  /// iPhone and iPad small controls: compact buttons, segmented control, tags with actions.
  public static let controlTouchSm: CGFloat = 36

  /// iPhone and iPad default controls and list rows (touch density).
  public static let controlTouchMd: CGFloat = 44

  /// iPhone and iPad primary call-to-action buttons and large text fields.
  public static let controlTouchLg: CGFloat = 50

  /// Mac small controls (compact density).
  public static let controlMacSm: CGFloat = 24

  /// Mac default buttons, fields, popup buttons and table rows.
  public static let controlMacMd: CGFloat = 28

  /// Mac large buttons and toolbar items.
  public static let controlMacLg: CGFloat = 32

  /// Minimum list row height on iPhone and iPad; grows with Dynamic Type.
  public static let rowTouch: CGFloat = 44

  /// Mac table and sidebar row height.
  public static let rowMac: CGFloat = 28

  /// iPadOS sidebar width in a split view.
  public static let sidebarIpad: CGFloat = 320

  /// macOS sidebar default width (resizable 200–320).
  public static let sidebarMac: CGFloat = 240

  /// Trailing inspector width on iPad and Mac.
  public static let inspector: CGFloat = 320

  /// Maximum text column on iPad and Mac (readableContentGuide).
  public static let readableWidth: CGFloat = 672

  /// Narrowest column of an adaptive column layout: the widest iPhone screen, so sections designed for iPhone fit a column without new wraps.
  public static let columnMinWidth: CGFloat = 440

  public static let tokens: [ShadowScalarToken] = [
    ShadowScalarToken(name: "tap-target", value: tapTarget),
    ShadowScalarToken(name: "control-touch-sm", value: controlTouchSm),
    ShadowScalarToken(name: "control-touch-md", value: controlTouchMd),
    ShadowScalarToken(name: "control-touch-lg", value: controlTouchLg),
    ShadowScalarToken(name: "control-mac-sm", value: controlMacSm),
    ShadowScalarToken(name: "control-mac-md", value: controlMacMd),
    ShadowScalarToken(name: "control-mac-lg", value: controlMacLg),
    ShadowScalarToken(name: "row-touch", value: rowTouch),
    ShadowScalarToken(name: "row-mac", value: rowMac),
    ShadowScalarToken(name: "sidebar-ipad", value: sidebarIpad),
    ShadowScalarToken(name: "sidebar-mac", value: sidebarMac),
    ShadowScalarToken(name: "inspector", value: inspector),
    ShadowScalarToken(name: "readable-width", value: readableWidth),
    ShadowScalarToken(name: "column-min-width", value: columnMinWidth),
  ]
}
