import Foundation
import ShadowDesignSystem
import SwiftUI
import Testing

struct ContrastCase: Sendable, CustomTestStringConvertible {
  let foreground: ShadowColorToken
  let background: ShadowColorToken
  let colorScheme: ColorScheme

  var testDescription: String { "\(foreground.rawValue) on \(background.rawValue) (\(colorScheme))" }

  var ratio: Double {
    // Translucent fills such as dark *-bg-subtle are composited over surface-card, where they sit.
    let base = ShadowColorToken.surfaceCard.rgba(for: colorScheme)
    let surface = background.rgba(for: colorScheme).composited(over: base)
    return foreground.rgba(for: colorScheme).composited(over: surface).contrastRatio(against: surface)
  }

  static func pairs(_ foregrounds: [ShadowColorToken], on backgrounds: [ShadowColorToken], in schemes: [ColorScheme] = ColorScheme.allCases) -> [Self] {
    foregrounds.flatMap { foreground in
      backgrounds.flatMap { background in schemes.map { Self(foreground: foreground, background: background, colorScheme: $0) } }
    }
  }

  static let documented: [Self] =
    pairs([.textPrimary, .textSecondary, .accentText], on: [.surfaceCard, .surfaceApp])
    + pairs([.textPrimary, .textSecondary], on: [.surfaceRaised])
    + pairs([.destructiveLabel, .textTertiary], on: [.surfaceCard])
    + pairs([.accentText], on: [.accentSoft])
    + pairs([.neutralText, .infoText], on: [.surfaceCard, .surfaceApp])
    + pairs([.dangerText], on: [.surfaceCard, .surfaceApp])
    + pairs([.neutralTextOnSubtle], on: [.neutralBgSubtle])
    + pairs([.successTextOnSubtle], on: [.successBgSubtle])
    + pairs([.warningTextOnSubtle], on: [.warningBgSubtle])
    + pairs([.dangerTextOnSubtle], on: [.dangerBgSubtle])
    + pairs([.infoTextOnSubtle], on: [.infoBgSubtle])
    + pairs([.onAccent], on: [.accent, .accentHover, .accentActive, .selectionRow])
    + pairs([.dangerOnSolid], on: [.dangerSolid, .dangerSolidHover, .dangerSolidActive])
    + pairs([.warningOnSolid], on: [.warningSolidStrong])
    + pairs([.neutralOnSolid], on: [.neutralSolid])
    + pairs([.textPrimary], on: [.bgHover, .bgPressed])
    + pairs([.accentText], on: [.surfaceCard])
}

@Suite("Text contrast")
struct ContrastTests {
  @Test("should reach 4.5:1 for every documented text pair", arguments: ContrastCase.documented)
  func reachesTextContrast(pair: ContrastCase) {
    #expect(pair.ratio >= 4.5, "\(pair.testDescription) is \(pair.ratio):1")
  }

  @Test("should reach 4.5:1 for white text on every swipe tile", arguments: ShadowRowActionKind.allCases, ColorScheme.allCases)
  func swipeTileContrast(kind: ShadowRowActionKind, scheme: ColorScheme) {
    let pair = ContrastCase(foreground: .onAccent, background: kind.token, colorScheme: scheme)
    #expect(pair.ratio >= 4.5, "\(pair.testDescription) is \(pair.ratio):1")
  }

  @Test("should compute WCAG contrast at its extremes")
  func computesReferenceRatios() {
    let black = ShadowRGBA(red: 0, green: 0, blue: 0)
    let white = ShadowRGBA(red: 1, green: 1, blue: 1)
    #expect(abs(black.contrastRatio(against: white) - 21) < 0.001)
    #expect(white.contrastRatio(against: white) == 1)
  }
}

extension ShadowRGBA {
  func composited(over background: ShadowRGBA) -> ShadowRGBA {
    func blend(_ top: Double, _ bottom: Double) -> Double { top * alpha + bottom * (1 - alpha) }
    return ShadowRGBA(red: blend(red, background.red), green: blend(green, background.green), blue: blend(blue, background.blue))
  }

  var relativeLuminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  func contrastRatio(against background: ShadowRGBA) -> Double {
    let luminances = [relativeLuminance, background.relativeLuminance].sorted(by: >)
    return (luminances[0] + 0.05) / (luminances[1] + 0.05)
  }
}
