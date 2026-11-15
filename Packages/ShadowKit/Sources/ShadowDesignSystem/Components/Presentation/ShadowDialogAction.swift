import SwiftUI

extension View {
  // SwiftUI on macOS binds Return to the first non-cancel dialog button, which would be the destructive one. Marking Cancel as the
  // default keeps Return safe; Escape reaches Cancel through its role either way.
  public func shadowDialogCancelAction() -> some View {
    #if os(macOS)
      keyboardShortcut(.defaultAction)
    #else
      self
    #endif
  }

  public func shadowDestructiveDialogAction() -> some View {
    #if os(macOS)
      keyboardShortcut(.delete, modifiers: .command)
    #else
      self
    #endif
  }
}
