import Foundation
import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Rating scale")
struct ShadowRatingScaleTests {
  private let scale = ShadowRatingScale()

  @Test("should clamp whole values to zero through the maximum", arguments: [(-2, 0), (0, 0), (3, 3), (5, 5), (9, 5)])
  func clampInt(value: Int, expected: Int) {
    #expect(scale.clamped(value) == expected)
  }

  @Test("should clamp fractional values and treat non-finite values safely")
  func clampDouble() {
    #expect(scale.clamped(-0.5) == 0)
    #expect(scale.clamped(7.2) == 5)
    #expect(scale.clamped(Double.nan) == 0)
    #expect(scale.clamped(Double.infinity) == 5)
  }

  @Test("should snap display values to the nearest half star", arguments: [(4.6, 4.5), (4.74, 4.5), (4.75, 5.0), (4.2, 4.0), (0.24, 0.0), (6.0, 5.0)])
  func snap(value: Double, expected: Double) {
    #expect(scale.displayValue(value) == expected)
  }

  @Test("should fill stars from the snapped value")
  func fills() {
    let fills = (0..<5).map { scale.fill(at: $0, for: 3.6) }
    #expect(fills == [.full, .full, .full, .half, .empty])
    #expect((0..<5).map { scale.fill(at: $0, for: 0) }.allSatisfy { $0 == .empty })
  }

  @Test("should map a touch offset to the star under it", arguments: [(-4.0, 0), (0.0, 1), (19.9, 1), (20.0, 2), (99.0, 5), (140.0, 5)])
  func offset(offset: Double, expected: Int) {
    #expect(scale.value(atOffset: offset, width: 100) == expected)
  }

  @Test("should step within the range")
  func step() {
    #expect(scale.stepped(4, by: 1) == 5)
    #expect(scale.stepped(5, by: 1) == 5)
    #expect(scale.stepped(0, by: -1) == 0)
  }

  @Test("should keep at least one star")
  func minimum() {
    #expect(ShadowRatingScale(maximum: 0).maximum == 1)
  }

  @Test("should mark only the stars between the committed value and the hover as previewed")
  func previewedStars() {
    let previewed = (0..<5).filter { scale.isPreviewed(at: $0, committed: 2, shown: 4) }
    #expect(previewed == [2, 3])
    #expect((0..<5).allSatisfy { !scale.isPreviewed(at: $0, committed: 4, shown: 2) })
    #expect((0..<5).allSatisfy { !scale.isPreviewed(at: $0, committed: 3, shown: 3) })
  }

  @Test("should give empty stars at least 3:1 against card surfaces")
  @MainActor
  func emptyStarContrast() {
    for scheme in ColorScheme.allCases {
      let ratio = ShadowColorToken.textTertiary.rgba(for: scheme).contrastRatio(against: ShadowColorToken.surfaceCard.rgba(for: scheme))
      #expect(ratio >= 3, "empty star in \(scheme) is \(ratio):1")
    }
  }
}
