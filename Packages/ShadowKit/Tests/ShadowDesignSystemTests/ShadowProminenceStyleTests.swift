import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Prominence style")
struct ShadowProminenceStyleTests {
  @Test("should switch to on-accent on a prominent selection", arguments: [ShadowColorToken.textPrimary, .textSecondary, .accentText])
  func prominent(standard: ShadowColorToken) {
    let style = ShadowProminenceStyle(standard)
    #expect(style.token(for: .increased) == .onAccent)
    #expect(style.token(for: .standard) == standard)
  }

  @Test("should resolve against the environment it is drawn in rather than the one its view was built in") @MainActor
  func resolvesAtRenderTime() {
    var environment = EnvironmentValues()
    environment.colorScheme = .light
    let style = ShadowProminenceStyle(.textPrimary)
    environment.backgroundProminence = .increased
    #expect(style.resolve(in: environment).resolve(in: environment) == ShadowColorToken.onAccent.color.resolve(in: environment))
    environment.backgroundProminence = .standard
    #expect(style.resolve(in: environment).resolve(in: environment) == ShadowColorToken.textPrimary.color.resolve(in: environment))
  }
}
