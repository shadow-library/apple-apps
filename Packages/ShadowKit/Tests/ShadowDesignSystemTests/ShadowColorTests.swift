import ShadowDesignSystem
import SwiftUI
import Testing

@MainActor
@Suite("ShadowColor")
struct ShadowColorTests {
  @Test("should resolve every semantic colour to its light and dark token value", arguments: ShadowColorToken.allCases)
  func resolvesPerAppearance(token: ShadowColorToken) {
    let light = token.color.resolve(in: .appearance(.light))
    let dark = token.color.resolve(in: .appearance(.dark))

    #expect(light.matches(token.light))
    #expect(dark.matches(token.dark))
    #expect((light != dark) == (token.light != token.dark))
  }

  @Test("should expose the generated token through the ShadowColor namespace")
  func namespaceMatchesToken() {
    #expect(ShadowColor.accent.resolve(in: .appearance(.dark)).matches(ShadowColorToken.accent.dark))
    #expect(ShadowColor.surfaceApp.resolve(in: .appearance(.light)).matches(ShadowColorToken.surfaceApp.light))
  }

  @Test("should resolve alias chains within the same theme")
  func resolvesAliasChains() {
    #expect(ShadowColorToken.accentText.light == ShadowColorToken.accent.light)
    #expect(ShadowColorToken.accentText.dark == ShadowRGBA(red: 0x82 / 255, green: 0x83 / 255, blue: 0xF0 / 255))
    #expect(ShadowColorToken.selectionRow.light == ShadowColorToken.accent.light)
    #expect(ShadowColorToken.selectionRow.dark == ShadowColorToken.accent.dark)
    #expect(ShadowColorToken.onAccent.light == ShadowRGBA(red: 1, green: 1, blue: 1))
    #expect(ShadowColorToken.onAccent.dark == ShadowColorToken.onAccent.light)
  }

  @Test("should keep rgba alpha from the source")
  func keepsAlpha() {
    #expect(ShadowColorToken.surfaceWell.dark == ShadowRGBA(red: 1, green: 1, blue: 1, alpha: 0.04))
    #expect(ShadowColorToken.scrim.dark.alpha == 0.72)
  }

  @Test("should not emit palette primitives")
  func omitsPrimitives() {
    #expect(ShadowColorToken(rawValue: "neutral-100") == nil)
    #expect(ShadowColorToken(rawValue: "indigo-600") == nil)
    #expect(ShadowColorToken(rawValue: "neutral-solid") == .neutralSolid)
  }
}

extension EnvironmentValues {
  static func appearance(_ colorScheme: ColorScheme) -> EnvironmentValues {
    var environment = EnvironmentValues()
    environment.colorScheme = colorScheme
    return environment
  }
}

extension Color.Resolved {
  func matches(_ rgba: ShadowRGBA) -> Bool {
    let tolerance = 0.5 / 255
    let pairs = [(red, rgba.red), (green, rgba.green), (blue, rgba.blue), (opacity, rgba.alpha)]
    return pairs.allSatisfy { abs(Double($0) - $1) <= tolerance }
  }
}
