import SwiftUI
import Testing

@_spi(Preview) @testable import ShadowDesignSystem

@Suite("Button metrics")
struct ShadowButtonMetricsTests {
  @Test("should use touch control heights as capsules", arguments: ShadowControlSize.allCases)
  func touchHeights(size: ShadowControlSize) {
    let metrics = ShadowButtonMetrics(density: .touch, size: size)
    #expect(metrics.visualHeight == ShadowDensity.touch.controlHeight(size))
    #expect(metrics.cornerRadius == metrics.visualHeight / 2)
  }

  @Test("should map touch sizes to 36, 44 and 50pt")
  func touchTokenValues() {
    let heights = ShadowControlSize.allCases.map { ShadowButtonMetrics(density: .touch, size: $0).visualHeight }
    #expect(heights == [ShadowMetrics.controlTouchSm, ShadowMetrics.controlTouchMd, ShadowMetrics.controlTouchLg])
  }

  @Test("should use Mac control heights as radius-md rounded rectangles", arguments: ShadowControlSize.allCases)
  func compactHeights(size: ShadowControlSize) {
    let metrics = ShadowButtonMetrics(density: .compact, size: size)
    #expect(metrics.visualHeight == ShadowDensity.compact.controlHeight(size))
    #expect(metrics.cornerRadius == Radius.md)
  }

  @Test("should keep glass buttons capsule-shaped on Mac")
  func compactGlassIsCapsule() {
    let metrics = ShadowButtonMetrics(density: .compact, size: .medium, isGlass: true)
    #expect(metrics.cornerRadius == ShadowMetrics.controlMacMd / 2)
  }

  @Test("should draw small touch buttons at 36pt inside a 44pt hit area")
  func smallTouchHitArea() {
    let metrics = ShadowButtonMetrics(density: .touch, size: .small)
    #expect(metrics.visualHeight == ShadowMetrics.controlTouchSm)
    #expect(metrics.hitSize == ShadowMetrics.tapTarget)
    #expect(metrics.layoutHeight == ShadowMetrics.tapTarget)
  }

  @Test("should lay out medium and large touch buttons at their visual height", arguments: [ShadowControlSize.medium, .large])
  func touchLayoutMatchesVisual(size: ShadowControlSize) {
    let metrics = ShadowButtonMetrics(density: .touch, size: size)
    #expect(metrics.layoutHeight == metrics.visualHeight)
  }

  @Test("should not pad the hit area on Mac", arguments: ShadowControlSize.allCases)
  func compactHitArea(size: ShadowControlSize) {
    let metrics = ShadowButtonMetrics(density: .compact, size: size)
    #expect(metrics.hitSize == 0)
    #expect(metrics.layoutHeight == metrics.visualHeight)
  }

  @Test("should make icon buttons square with no horizontal padding", arguments: ShadowDensity.allCases, ShadowControlSize.allCases)
  func iconLayout(density: ShadowDensity, size: ShadowControlSize) {
    let metrics = ShadowButtonMetrics(density: density, size: size, layout: .icon)
    #expect(metrics.visualWidth == metrics.visualHeight)
    #expect(metrics.horizontalPadding == 0)
  }

  @Test("should set touch labels in headline weight and Mac labels in medium weight")
  func labelWeights() {
    #expect(ShadowButtonMetrics(density: .touch, size: .medium).labelWeight == .semibold)
    #expect(ShadowButtonMetrics(density: .touch, size: .medium).labelStyle == .headline)
    #expect(ShadowButtonMetrics(density: .compact, size: .medium).labelWeight == .medium)
    #expect(ShadowButtonMetrics(density: .compact, size: .medium).labelStyle == .body)
  }
}

@Suite("Button variants")
struct ShadowButtonVariantTests {
  @Test("should keep every variant as requested on the navigation layer")
  func navigationLayer() {
    let appearances = ShadowButtonVariant.allCases.map { $0.appearance(in: .navigation) }
    #expect(appearances == [.filled, .tinted, .bordered, .plain, .glass, .glassProminent])
  }

  @Test("should never draw glass on glass")
  func glassLayer() {
    let appearances = ShadowButtonVariant.allCases.map { $0.appearance(in: .glass) }
    #expect(appearances.allSatisfy { !$0.isGlass })
    #expect(ShadowButtonVariant.glass.appearance(in: .glass) == .barItem)
    #expect(ShadowButtonVariant.plain.appearance(in: .glass) == .barItem)
  }

  @Test("should fall back to opaque styles for glass inside content")
  func contentLayer() {
    #expect(ShadowButtonVariant.glass.appearance(in: .content) == .bordered)
    #expect(ShadowButtonVariant.glassProminent.appearance(in: .content) == .filled)
    #expect(ShadowButtonVariant.allCases.allSatisfy { !$0.appearance(in: .content).isGlass })
  }

  @Test("should allow glass only on the navigation layer")
  func layerRule() {
    #expect(ShadowMaterialLayer.allCases.filter(\.allowsGlass) == [.navigation])
  }
}

@MainActor
@Suite("Button palette")
struct ShadowButtonPaletteTests {
  @Test("should fill with accent, accent-hover and accent-active")
  func filledStates() {
    let fills = ShadowButtonInteraction.allCases.map { ShadowButtonPalette(appearance: .filled, isDestructive: false, interaction: $0).fill }
    #expect(fills == [ShadowColor.accent, ShadowColor.accentHover, ShadowColor.accentActive])
  }

  @Test("should use danger-solid for a filled destructive button")
  func filledDestructive() {
    let palette = ShadowButtonPalette(appearance: .filled, isDestructive: true, interaction: .idle)
    #expect(palette.fill == ShadowColor.dangerSolid)
    #expect(palette.foreground == ShadowColor.dangerOnSolid)
  }

  @Test(
    "should use destructive-label text for bordered, plain and glass destructive buttons", arguments: [ShadowButtonAppearance.bordered, .plain, .barItem, .glass, .glassProminent])
  func destructiveLabel(appearance: ShadowButtonAppearance) {
    #expect(ShadowButtonPalette(appearance: appearance, isDestructive: true, interaction: .idle).foreground == ShadowColor.destructiveLabel)
  }

  @Test("should never tint glass with a status colour")
  func glassHasNoFill() {
    for appearance in [ShadowButtonAppearance.glass, .glassProminent] {
      #expect(ShadowButtonPalette(appearance: appearance, isDestructive: true, interaction: .pressed).fill == nil)
    }
  }

  @Test("should strengthen the bordered edge under Increase Contrast")
  func increasedContrast() {
    #expect(ShadowButtonPalette(appearance: .bordered, isDestructive: false, interaction: .idle).border == ShadowColor.borderDefault)
    #expect(ShadowButtonPalette(appearance: .bordered, isDestructive: false, interaction: .idle, increasedContrast: true).border == ShadowColor.borderStrong)
  }

  @Test("should give plain buttons a shape when Button Shapes is on")
  func buttonShapes() {
    #expect(ShadowButtonPalette(appearance: .plain, isDestructive: false, interaction: .idle).fill == nil)
    #expect(ShadowButtonPalette(appearance: .plain, isDestructive: false, interaction: .idle, showsButtonShapes: true).fill == ShadowColor.surfaceWell)
  }

  @Test("should take the glass foreground for bar items")
  func barItemForeground() {
    let palette = ShadowButtonPalette(appearance: .barItem, isDestructive: false, interaction: .idle, glassForeground: ShadowColor.onAccent)
    #expect(palette.foreground == ShadowColor.onAccent)
  }
}

@Suite("Button spinner")
struct ShadowButtonSpinnerTests {
  @Test("should turn one revolution per period and wrap")
  func angle() {
    let period = ShadowButtonSpinner.revolution
    #expect(ShadowButtonSpinner.angle(at: Date(timeIntervalSinceReferenceDate: 0)).degrees == 0)
    #expect(abs(ShadowButtonSpinner.angle(at: Date(timeIntervalSinceReferenceDate: period / 2)).degrees - 180) < 0.001)
    #expect(abs(ShadowButtonSpinner.angle(at: Date(timeIntervalSinceReferenceDate: period * 3 + period / 4)).degrees - 90) < 0.001)
  }
}
