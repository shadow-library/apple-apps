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

@Suite("Table selection band")
struct ShadowTableSelectionBandTests {
  @Test("should put only the selected rows of a focused, active table on the band")
  func focusedSelection() {
    let band = ShadowTableSelectionBand(selection: Set(["chapter-released", "step-up-code"]), isFocused: true, appearsActive: true)
    #expect(band.isOnBand(row: "chapter-released"))
    #expect(band.isOnBand(row: "step-up-code"))
    #expect(!band.isOnBand(row: "welcome-email"))
  }

  @Test("should keep every row off the band while the table is unfocused or its window is inactive", arguments: [(false, true), (true, false), (false, false)])
  func greyBand(isFocused: Bool, appearsActive: Bool) {
    let band = ShadowTableSelectionBand(selection: Set(["step-up-code"]), isFocused: isFocused, appearsActive: appearsActive)
    #expect(!band.isOnBand(row: "step-up-code"))
  }

  @Test("should keep every row off the band with an empty selection")
  func emptySelection() {
    let band = ShadowTableSelectionBand(selection: Set<Int>(), isFocused: true, appearsActive: true)
    #expect(!band.isOnBand(row: 1))
  }

  @Test("should not match a row identifier of another type")
  func identifierType() {
    let band = ShadowTableSelectionBand(selection: Set([1]), isFocused: true, appearsActive: true)
    #expect(band.isOnBand(row: 1))
    #expect(!band.isOnBand(row: "1"))
  }

  @Test("should compare equal for the same selection and state")
  func equality() {
    let band = ShadowTableSelectionBand(selection: Set([1, 2]), isFocused: true, appearsActive: true)
    #expect(band == ShadowTableSelectionBand(selection: Set([2, 1]), isFocused: true, appearsActive: true))
    #expect(band != ShadowTableSelectionBand(selection: Set([1]), isFocused: true, appearsActive: true))
    #expect(band != ShadowTableSelectionBand(selection: Set([1, 2]), isFocused: true, appearsActive: false))
  }

  @Test("should report a band row as prominent whatever the platform reports")
  func selectionProminence() {
    var environment = EnvironmentValues()
    environment.backgroundProminence = .standard
    #expect(environment.shadowSelectionProminence == .standard)
    environment.shadowTableRowIsOnSelectionBand = true
    #expect(environment.shadowSelectionProminence == .increased)
    environment.shadowTableRowIsOnSelectionBand = false
    environment.backgroundProminence = .increased
    #expect(environment.shadowSelectionProminence == .increased)
  }

  @Test("should draw on-accent labels and the outline badge on a band row the platform reports as standard") @MainActor
  func bandRowStyles() {
    var environment = EnvironmentValues()
    environment.colorScheme = .light
    environment.backgroundProminence = .standard
    environment.shadowSelectionIsAccentBand = true
    environment.shadowTableRowIsOnSelectionBand = true
    let label = ShadowProminenceStyle(.textPrimary)
    let badge = ShadowBadgeStyle(intent: .danger, role: .foreground)
    #expect(label.resolve(in: environment).resolve(in: environment) == ShadowColorToken.onAccent.color.resolve(in: environment))
    #expect(badge.resolve(in: environment).resolve(in: environment) == ShadowColorToken.onAccent.color.resolve(in: environment))
    #expect(ShadowBadgeStyle(intent: .danger, role: .fill).resolve(in: environment).resolve(in: environment) == Color.clear.resolve(in: environment))
    environment.shadowTableRowIsOnSelectionBand = false
    #expect(label.resolve(in: environment).resolve(in: environment) == ShadowColorToken.textPrimary.color.resolve(in: environment))
    #expect(badge.resolve(in: environment).resolve(in: environment) == ShadowColorToken.dangerTextOnSubtle.color.resolve(in: environment))
  }

  @Test("should keep touch list badges on their intent colours") @MainActor
  func touchListBadge() {
    var environment = EnvironmentValues()
    environment.shadowSelectionIsAccentBand = false
    environment.shadowTableRowIsOnSelectionBand = true
    #expect(ShadowBadgeStyle(intent: .danger, role: .border).resolve(in: environment).resolve(in: environment) == ShadowBadgeIntent.danger.border.color.resolve(in: environment))
  }
}
