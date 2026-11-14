import ShadowDesignSystem
import SwiftUI
import Testing

@MainActor
@Suite("ShadowTextStyle")
struct ShadowTextStyleTests {
  @Test("should resolve semantic roles to the current platform's styles")
  func resolvesRoles() {
    let roles: [ShadowTextStyle] = [.largeTitle, .title, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption, .caption2]
    #if os(macOS)
      let prefix = "mac-"
    #else
      let prefix = "ios-"
    #endif
    #expect(roles.allSatisfy { $0.rawValue.hasPrefix(prefix) })
  }

  #if os(macOS)
    @Test(
      "should match the token point size and weight of each Mac and mono style",
      arguments: [
        (ShadowTextStyle.macLargeTitle, 26.0, Font.Weight.bold), (.macTitle1, 22, .semibold), (.macTitle2, 17, .semibold), (.macTitle3, 15, .semibold),
        (.macHeadline, 13, .semibold), (.macBody, 13, .regular), (.macCallout, 12, .regular), (.macSubheadline, 11, .medium),
        (.macFootnote, 11, .regular), (.macCaption, 10, .medium), (.monoBody, 13, .regular), (.monoFigure, 17, .medium),
      ]
    )
    func matchesMacTokens(style: ShadowTextStyle, pointSize: CGFloat, weight: Font.Weight) {
      let resolved = style.font.resolve(in: EnvironmentValues().fontResolutionContext)
      #expect(resolved.pointSize == pointSize)
      #expect(style.weight == weight)
    }
  #endif

  @Test("should set mono-body in SF Mono and keep figures tabular")
  func usesMonospacedFonts() {
    #expect(ShadowTextStyle.monoBody.design == .monospaced)
    #expect(ShadowTextStyle.monoBody.font.resolve(in: EnvironmentValues().fontResolutionContext).isMonospaced)
    #expect(ShadowTextStyle.monoFigure.font == Font.system(ShadowTextStyle.monoFigure.textStyle, design: .default, weight: .medium).monospacedDigit())
  }

  @Test("should expose the Shadow font through Font")
  func exposesFont() {
    #expect(Font.shadow(.headline) == ShadowTextStyle.headline.font)
  }
}

@Suite("ShadowMotion")
struct ShadowMotionTests {
  @Test("should map motion tokens to the brand book's springs")
  func mapsSprings() {
    #expect(Animation.shadow(.fast) == .snappy)
    #expect(Animation.shadow(.normal) == .smooth)
    #expect(Animation.shadow(.emphasized) == .bouncy(duration: 0.35))
  }

  @Test("should replace springs with eased fades under Reduce Motion")
  func reducesMotion() {
    #expect(Animation.shadow(.fast, reduceMotion: true) == .easeInOut(duration: 0.15))
    #expect(Animation.shadow(.normal, reduceMotion: true) == .easeInOut(duration: 0.2))
    #expect(Animation.shadow(.emphasized, reduceMotion: true) == .easeInOut(duration: 0.35))
  }
}
