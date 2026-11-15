import Foundation
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
