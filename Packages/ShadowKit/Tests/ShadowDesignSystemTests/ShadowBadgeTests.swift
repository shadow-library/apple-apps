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
