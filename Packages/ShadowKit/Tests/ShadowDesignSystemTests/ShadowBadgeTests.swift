import Foundation
import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Badge count")
struct ShadowBadgeCountTests {
  private let english = Locale(identifier: "en_US")

  @Test("should show the number up to the maximum", arguments: [(1, "1"), (12, "12"), (99, "99")])
  func shows(value: Int, expected: String) {
    #expect(ShadowBadgeCount(value).text(locale: english) == expected)
  }

  @Test("should cap values above 99 as 99+", arguments: [100, 101, 1_000, Int.max])
  func caps(value: Int) {
    let count = ShadowBadgeCount(value)
    #expect(count.isCapped)
    #expect(count.text(locale: english) == "99+")
  }

  @Test("should hide zero and negative counts", arguments: [0, -1, Int.min])
  func hides(value: Int) {
    #expect(!ShadowBadgeCount(value).isVisible)
  }

  @Test("should honour a custom maximum and group digits")
  func customMaximum() {
    #expect(ShadowBadgeCount(1_500, maximum: 999).text(locale: english) == "999+")
    #expect(ShadowBadgeCount(1_500, maximum: 9_999).text(locale: english) == "1,500")
  }

  @Test("should treat a maximum below one as one")
  func clampsMaximum() {
    #expect(ShadowBadgeCount(5, maximum: 0).text(locale: english) == "1+")
  }
}

@Suite("Badge placement")
struct ShadowBadgePlacementTests {
  @Test("should anchor on the 45-degree point of a circular control", arguments: [ShadowDensity.touch, .compact])
  func anchorsOnCircle(density: ShadowDensity) {
    let side: CGFloat = density == .touch ? 44 : 28
    let anchor = ShadowBadgePlacement(density: density).anchor(in: CGSize(width: side, height: side))
    let radius = side / 2
    let distance = ((anchor.x - radius) * (anchor.x - radius) + (anchor.y - radius) * (anchor.y - radius)).squareRoot()
    #expect(abs(distance - radius) < 0.001)
    #expect(anchor.x > radius && anchor.y < radius)
  }

  @Test("should keep the leading edge fixed so wider counts grow outward")
  func growsOutward() {
    let placement = ShadowBadgePlacement(density: .touch)
    let content = CGSize(width: 44, height: 44)
    let one = placement.origin(for: CGSize(width: 20, height: 20), in: content)
    let many = placement.origin(for: CGSize(width: 34, height: 20), in: content)
    #expect(one == many)
  }

  @Test("should overlap the content by at most the density's limit", arguments: [ShadowDensity.touch, .compact])
  func limitsOverlap(density: ShadowDensity) {
    let placement = ShadowBadgePlacement(density: density)
    let content = CGSize(width: 44, height: 44)
    let badge = CGSize(width: 30, height: 24)
    let origin = placement.origin(for: badge, in: content)
    #expect(placement.anchor(in: content).x - origin.x == placement.maximumOverlap)
    #expect(origin.y + badge.height / 2 == placement.anchor(in: content).y)
  }

  @Test("should centre a dot on the anchor")
  func centresDot() {
    let placement = ShadowBadgePlacement(density: .touch)
    let content = CGSize(width: 32, height: 32)
    let dot = CGSize(width: 10, height: 10)
    let origin = placement.origin(for: dot, in: content)
    let anchor = placement.anchor(in: content)
    #expect(abs(origin.x + dot.width / 2 - anchor.x) < 0.001)
    #expect(abs(origin.y + dot.height / 2 - anchor.y) < 0.001)
  }
}

@Suite("Badge on a selection band")
struct ShadowBadgeStyleTests {
  @Test("should keep the intent tokens off the selection band", arguments: ShadowBadgeIntent.allCases)
  func standard(intent: ShadowBadgeIntent) {
    #expect(ShadowBadgeStyle(intent: intent, role: .fill).token(isOnSelectionBand: false) == intent.fill)
    #expect(ShadowBadgeStyle(intent: intent, role: .border).token(isOnSelectionBand: false) == intent.border)
    #expect(ShadowBadgeStyle(intent: intent, role: .foreground).token(isOnSelectionBand: false) == intent.foreground)
  }

  @Test("should become an on-accent outline with no fill on the selection band", arguments: ShadowBadgeIntent.allCases)
  func onBand(intent: ShadowBadgeIntent) {
    #expect(ShadowBadgeStyle(intent: intent, role: .fill).token(isOnSelectionBand: true) == nil)
    #expect(ShadowBadgeStyle(intent: intent, role: .border).token(isOnSelectionBand: true) == .onAccent)
    #expect(ShadowBadgeStyle(intent: intent, role: .foreground).token(isOnSelectionBand: true) == .onAccent)
  }

  @Test("should treat only a prominent accent band as the selection band")
  func selectionBand() {
    #expect(ShadowBadgeStyle.isOnSelectionBand(prominence: .increased, selectionIsAccentBand: true))
    #expect(!ShadowBadgeStyle.isOnSelectionBand(prominence: .standard, selectionIsAccentBand: true))
    #expect(!ShadowBadgeStyle.isOnSelectionBand(prominence: .increased, selectionIsAccentBand: false))
  }

  @Test("should use the accent band by default only on macOS")
  func platformDefault() {
    #if os(macOS)
      #expect(EnvironmentValues().shadowSelectionIsAccentBand)
    #else
      #expect(!EnvironmentValues().shadowSelectionIsAccentBand)
    #endif
  }

  @Test("should resolve against the environment it is drawn in") @MainActor
  func resolvesAtRenderTime() {
    var environment = EnvironmentValues()
    environment.colorScheme = .dark
    environment.shadowSelectionIsAccentBand = true
    let style = ShadowBadgeStyle(intent: .danger, role: .foreground)
    environment.backgroundProminence = .increased
    #expect(style.resolve(in: environment).resolve(in: environment) == ShadowColorToken.onAccent.color.resolve(in: environment))
    #expect(ShadowBadgeStyle(intent: .danger, role: .fill).resolve(in: environment).resolve(in: environment) == Color.clear.resolve(in: environment))
    environment.backgroundProminence = .standard
    #expect(style.resolve(in: environment).resolve(in: environment) == ShadowColorToken.dangerTextOnSubtle.color.resolve(in: environment))
  }
}

@Suite("Neutral badge")
struct ShadowNeutralBadgeTests {
  @Test("should differ from the app surface in fill and border in both themes", arguments: ColorScheme.allCases)
  func standsOffTheAppSurface(scheme: ColorScheme) {
    let app = ShadowColorToken.surfaceApp.rgba(for: scheme)
    let fill = ShadowBadgeIntent.neutral.fill.rgba(for: scheme)
    let border = ShadowBadgeIntent.neutral.border.rgba(for: scheme)
    #expect(fill != app)
    #expect(border != app)
    #expect(fill.contrastRatio(against: app) > 1.05 || border.contrastRatio(against: app) > 1.3)
  }

  @Test("should reach 4.5:1 for its text on its fill", arguments: ColorScheme.allCases)
  func textContrast(scheme: ColorScheme) {
    let fill = ShadowBadgeIntent.neutral.fill.rgba(for: scheme).composited(over: ShadowColorToken.surfaceApp.rgba(for: scheme))
    let text = ShadowBadgeIntent.neutral.foreground.rgba(for: scheme)
    #expect(text.contrastRatio(against: fill) >= 4.5)
  }
}
