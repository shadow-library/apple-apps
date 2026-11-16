import SwiftUI

// macOS 26 List and Table rows only expose the focused selection's `.increased` prominence at render time: a view's
// `@Environment(\.backgroundProminence)` keeps the value from its last body evaluation, which does not rerun when focus moves.
nonisolated struct ShadowProminenceStyle: ShapeStyle {
  let standard: ShadowColorToken
  let prominent: ShadowColorToken

  init(_ standard: ShadowColorToken, prominent: ShadowColorToken = .onAccent) {
    self.standard = standard
    self.prominent = prominent
  }

  // Touch list rows take on-accent from their body-time phase; iPad also reports `.increased` under the row's own accent-soft selection.
  static func listRowLabel(_ token: ShadowColorToken) -> Self {
    #if os(macOS)
      Self(token)
    #else
      Self(token, prominent: token)
    #endif
  }

  func resolve(in environment: EnvironmentValues) -> Color {
    token(for: environment.shadowSelectionProminence).color
  }

  func token(for prominence: BackgroundProminence) -> ShadowColorToken {
    prominence == .increased ? prominent : standard
  }
}
