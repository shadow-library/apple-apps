import Testing

@testable import ShadowDesignSystem

@Suite("Skeleton metrics")
struct ShadowSkeletonMetricsTests {
  @Test("should size bars to each density's text so Mac bars stay thinner than touch bars", arguments: [ShadowSkeletonLine.Role.title, .body])
  func density(role: ShadowSkeletonLine.Role) {
    #expect(ShadowSkeletonMetrics.lineHeight(role, density: .compact) < ShadowSkeletonMetrics.lineHeight(role, density: .touch))
  }

  @Test("should keep title bars taller than body bars", arguments: ShadowDensity.allCases)
  func hierarchy(density: ShadowDensity) {
    #expect(ShadowSkeletonMetrics.lineHeight(.title, density: density) > ShadowSkeletonMetrics.lineHeight(.body, density: density))
  }
}
