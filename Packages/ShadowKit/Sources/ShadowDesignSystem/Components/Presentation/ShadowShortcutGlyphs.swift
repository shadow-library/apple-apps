import SwiftUI

nonisolated public enum ShadowShortcutGlyphs {
  private static let modifierOrder: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]

  private static let keyGlyphs: [KeyEquivalent: String] = [
    .return: "↩", .delete: "⌫", .deleteForward: "⌦", .escape: "⎋", .tab: "⇥", .space: "␣", .upArrow: "↑", .downArrow: "↓", .leftArrow: "←",
    .rightArrow: "→", .home: "↖", .end: "↘", .pageUp: "⇞", .pageDown: "⇟", .clear: "⌧",
  ]

  public static func string(for shortcut: KeyboardShortcut) -> String {
    let modifiers = modifierOrder.filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined()
    return modifiers + key(shortcut.key)
  }

  static func key(_ key: KeyEquivalent) -> String {
    keyGlyphs[key] ?? String(key.character).uppercased()
  }
}
