import ShadowDesignSystem
import SwiftUI
import Testing

@Suite("Token scales")
struct TokenScaleTests {
  @Test("should list spacing tokens in strictly increasing order")
  func spacingIncreases() {
    let values = Spacing.tokens.map(\.value)
    #expect(!values.isEmpty)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test("should list radius tokens in strictly increasing order")
  func radiusIncreases() {
    let values = Radius.tokens.map(\.value)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test("should map token names to Swift names traceably")
  func mapsNames() {
    #expect(Spacing.tokens.value(named: "space-0-5") == Spacing.space05)
    #expect(Spacing.tokens.value(named: "space-10") == Spacing.space10)
    #expect(Radius.tokens.value(named: "radius-2xl") == Radius.xxl)
    #expect(ShadowMetrics.tokens.value(named: "control-touch-md") == ShadowMetrics.controlTouchMd)
    #expect(ShadowOpacity.tokens.value(named: "disabled-opacity") == CGFloat(ShadowOpacity.disabled))
  }

  @Test("should drop every shadow but glass in dark mode")
  func dropsDarkShadows() {
    for elevation in [ShadowElevation.e1, .e2, .e3] {
      #expect(!elevation.light.isEmpty)
      #expect(elevation.layers(for: .dark).isEmpty)
    }
    #expect(ShadowElevation.glass.layers(for: .dark).count == 1)
    #expect(ShadowElevation.glass.layers(for: .light).count == 2)
  }
}

@Suite("ShadowMetrics")
struct ShadowMetricsTests {
  @Test("should use touch density for controls and rows on touch platforms")
  func touchDensity() {
    #expect(ShadowControlSize.allCases.map(ShadowDensity.touch.controlHeight) == [36, 44, 50])
    #expect(ShadowDensity.touch.rowHeight == 44)
    #expect(ShadowDensity.touch.sidebarWidth == 320)
  }

  @Test("should use compact density for controls and rows on Mac")
  func compactDensity() {
    #expect(ShadowControlSize.allCases.map(ShadowDensity.compact.controlHeight) == [24, 28, 32])
    #expect(ShadowDensity.compact.rowHeight == 28)
    #expect(ShadowDensity.compact.sidebarWidth == 240)
  }

  @Test("should resolve adaptive metrics from the platform's density")
  func resolvesPlatformDensity() {
    #if os(macOS)
      #expect(ShadowDensity.current == .compact)
    #else
      #expect(ShadowDensity.current == .touch)
    #endif
    #expect(ShadowMetrics.control(.medium) == ShadowDensity.current.controlHeight(.medium))
    #expect(ShadowMetrics.rowHeight == ShadowDensity.current.rowHeight)
  }

  @Test("should map SwiftUI control sizes to Shadow control sizes")
  func mapsControlSize() {
    #expect([ControlSize.mini, .small, .regular, .large, .extraLarge].map(ShadowControlSize.init) == [.small, .small, .medium, .large, .large])
  }
}

extension [ShadowScalarToken] {
  func value(named name: String) -> CGFloat? {
    first { $0.name == name }?.value
  }
}
