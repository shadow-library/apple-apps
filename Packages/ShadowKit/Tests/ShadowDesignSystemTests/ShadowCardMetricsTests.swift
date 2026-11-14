import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Card metrics")
struct ShadowCardMetricsTests {
  @Test("should use radius-section, 16pt padding and no border on touch")
  func touch() {
    let metrics = ShadowCardMetrics(density: .touch)
    #expect(metrics.cornerRadius == Radius.section)
    #expect(metrics.padding == EdgeInsets(top: Spacing.space4, leading: Spacing.space4, bottom: Spacing.space4, trailing: Spacing.space4))
    #expect(metrics.borderWidth == 0)
  }

  @Test("should use radius-lg, 12–16pt padding and a 1pt border on Mac")
  func compact() {
    let metrics = ShadowCardMetrics(density: .compact)
    #expect(metrics.cornerRadius == Radius.lg)
    #expect(metrics.verticalPadding == Spacing.space3)
    #expect(metrics.horizontalPadding == Spacing.space4)
    #expect(metrics.borderWidth == 1)
  }

  @Test("should keep inner corners concentric and never below radius-sm", arguments: ShadowDensity.allCases)
  func concentric(density: ShadowDensity) {
    let metrics = ShadowCardMetrics(density: density)
    #expect(metrics.innerCornerRadius == max(metrics.cornerRadius - min(metrics.horizontalPadding, metrics.verticalPadding), Radius.sm))
  }
}
