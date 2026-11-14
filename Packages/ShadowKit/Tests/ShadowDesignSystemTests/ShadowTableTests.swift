import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Table layout")
struct ShadowTableTests {
  @Test("should use a list in compact width and a grid otherwise")
  func layout() {
    #expect(ShadowTableLayout(horizontalSizeClass: .compact) == .list)
    #expect(ShadowTableLayout(horizontalSizeClass: .regular) == .grid)
    #expect(ShadowTableLayout(horizontalSizeClass: nil) == .grid)
  }

  @Test("should fall back to a list at accessibility type sizes")
  func accessibilitySize() {
    #expect(ShadowTableLayout(horizontalSizeClass: .regular, isAccessibilitySize: true) == .list)
    #expect(ShadowTableLayout(horizontalSizeClass: nil, isAccessibilitySize: true) == .list)
  }

  @Test("should keep skeleton rows between one and twelve", arguments: [(-2, 1), (0, 1), (5, 5), (40, 12)])
  func skeletonRows(requested: Int, expected: Int) {
    #expect(ShadowTableMetrics.skeletonRows(requested) == expected)
  }

  private struct Row: Identifiable, Sendable {
    let id: Int
    let name: String
    let size: Int
  }

  @Test("should start a new sort ascending as given")
  func selectNew() {
    let current = [KeyPathComparator(\Row.name)]
    let result = ShadowTableCompactSort<Row>.selecting(KeyPathComparator(\Row.size, order: .reverse), from: current)
    #expect(result.count == 1)
    #expect(result[0].keyPath == \Row.size)
    #expect(result[0].order == .reverse)
  }

  @Test("should reverse the order when the active column is chosen again")
  func toggle() {
    let forward = ShadowTableCompactSort<Row>.selecting(KeyPathComparator(\Row.name), from: [KeyPathComparator(\Row.name)])
    #expect(forward[0].order == .reverse)
    let back = ShadowTableCompactSort<Row>.selecting(KeyPathComparator(\Row.name), from: forward)
    #expect(back[0].order == .forward)
  }

  @Test("should report the first comparator as the active option")
  func active() {
    let current = [KeyPathComparator(\Row.size), KeyPathComparator(\Row.name)]
    #expect(ShadowTableCompactSort<Row>.isActive(KeyPathComparator(\Row.size), in: current))
    #expect(!ShadowTableCompactSort<Row>.isActive(KeyPathComparator(\Row.name), in: current))
    #expect(!ShadowTableCompactSort<Row>.isActive(KeyPathComparator(\Row.name), in: []))
  }
}
