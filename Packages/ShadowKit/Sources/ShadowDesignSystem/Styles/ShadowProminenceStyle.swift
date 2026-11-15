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

  func resolve(in environment: EnvironmentValues) -> Color {
    token(for: environment.backgroundProminence).color
  }

  func token(for prominence: BackgroundProminence) -> ShadowColorToken {
    prominence == .increased ? prominent : standard
  }
}
