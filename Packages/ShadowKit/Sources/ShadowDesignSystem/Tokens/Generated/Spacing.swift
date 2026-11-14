// Generated from Design/tokens.json by Scripts/generate-design-tokens.swift. Do not edit; run `mise run tokens`.

import CoreGraphics

nonisolated public enum Spacing {
  /// Gap between a row title and its subtitle.
  public static let space05: CGFloat = 2

  /// Icon-to-label gap inside tags and badges; segmented track padding.
  public static let space1: CGFloat = 4

  /// Gap between related controls in a button group; Mac row vertical padding.
  public static let space2: CGFloat = 8

  /// Row horizontal padding on Mac; gap between a symbol and its row title.
  public static let space3: CGFloat = 12

  /// iPhone screen margin and inset grouped list padding; card padding on Mac.
  public static let space4: CGFloat = 16

  /// iPad and Mac window content margin; card padding on iPhone and iPad.
  public static let space5: CGFloat = 20

  /// Gap between list sections; sheet content padding.
  public static let space6: CGFloat = 24

  /// Space above a section's first header; gap between major regions on iPad and Mac.
  public static let space8: CGFloat = 32

  /// Empty-state vertical padding.
  public static let space10: CGFloat = 40

  public static let tokens: [ShadowScalarToken] = [
    ShadowScalarToken(name: "space-0-5", value: space05),
    ShadowScalarToken(name: "space-1", value: space1),
    ShadowScalarToken(name: "space-2", value: space2),
    ShadowScalarToken(name: "space-3", value: space3),
    ShadowScalarToken(name: "space-4", value: space4),
    ShadowScalarToken(name: "space-5", value: space5),
    ShadowScalarToken(name: "space-6", value: space6),
    ShadowScalarToken(name: "space-8", value: space8),
    ShadowScalarToken(name: "space-10", value: space10),
  ]
}
