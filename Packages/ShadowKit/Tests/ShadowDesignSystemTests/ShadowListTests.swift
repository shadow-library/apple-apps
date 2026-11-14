import Foundation
import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("List row metrics")
struct ShadowListMetricsTests {
  @Test("should use 44pt rows and a chevron on touch")
  func touch() {
    let metrics = ShadowListMetrics(density: .touch)
    #expect(metrics.minimumRowHeight == ShadowMetrics.rowTouch)
    #expect(metrics.showsChevron)
    #expect(metrics.tileSize == 30)
  }

  @Test("should use 28pt rows and no chevron on Mac")
  func compact() {
    let metrics = ShadowListMetrics(density: .compact)
    #expect(metrics.minimumRowHeight == ShadowMetrics.rowMac)
    #expect(!metrics.showsChevron)
    #expect(metrics.tileSize == 20)
  }

  @Test("should grow to two lines before truncating", arguments: ShadowDensity.allCases)
  func lineLimit(density: ShadowDensity) {
    #expect(ShadowListMetrics(density: density).textLineLimit == 2)
  }

  @Test("should inset separators to the text when a leading view is present", arguments: ShadowDensity.allCases)
  func separatorInset(density: ShadowDensity) {
    let metrics = ShadowListMetrics(density: density)
    #expect(metrics.separatorInset(leadingWidth: nil) == metrics.horizontalPadding)
    #expect(metrics.separatorInset(leadingWidth: metrics.tileSize) == metrics.horizontalPadding + metrics.tileSize + metrics.leadingGap)
  }

  @Test("should fit one text line inside the minimum row height", arguments: ShadowDensity.allCases)
  func fitsMinimumHeight(density: ShadowDensity) {
    let metrics = ShadowListMetrics(density: density)
    #expect(metrics.verticalPadding * 2 < metrics.minimumRowHeight)
  }
}

@Suite("List row palette")
struct ShadowListRowPaletteTests {
  @Test("should select with accent-soft and accent-text on touch")
  func touchSelected() {
    let palette = ShadowListRowPalette(density: .touch, phase: .selected)
    #expect(palette.background == .accentSoft)
    #expect(palette.title == .accentText)
  }

  @Test("should select with selection-row and on-accent while focused on Mac")
  func macSelected() {
    let palette = ShadowListRowPalette(density: .compact, phase: .selected)
    #expect(palette.background == .selectionRow)
    #expect(palette.title == .onAccent)
    #expect(palette.secondary == .onAccent)
  }

  @Test("should fall back to a neutral selection when the Mac window is inactive")
  func macInactive() {
    let palette = ShadowListRowPalette(density: .compact, phase: .selectedInactive)
    #expect(palette.background == .bgPressed)
    #expect(palette.title == .textPrimary)
  }

  @Test("should use bg-hover on hover and surface-card at rest")
  func hoverAndRest() {
    #expect(ShadowListRowPalette(density: .compact, phase: .hovered).background == .bgHover)
    #expect(ShadowListRowPalette(density: .touch, phase: .standard).background == .surfaceCard)
  }

  @Test("should keep the destructive label colour in every phase", arguments: [ShadowListRowPhase.standard, .hovered, .selected, .selectedInactive])
  func destructive(phase: ShadowListRowPhase) {
    for density in ShadowDensity.allCases {
      #expect(ShadowListRowPalette(density: density, phase: phase, isDestructive: true).title == .destructiveLabel)
    }
  }
}

@Suite("Row actions")
struct ShadowRowActionTests {
  private typealias Entry = (name: String, kind: ShadowRowActionKind)

  @Test("should place the destructive action outermost on the trailing edge")
  func destructiveFirst() {
    let actions: [Entry] = [("flag", .warning), ("delete", .destructive), ("archive", .neutral)]
    #expect(ShadowRowActionLayout.trailing(actions, kind: \.kind).map(\.name) == ["delete", "flag", "archive"])
  }

  @Test("should keep at most three trailing actions")
  func trailingLimit() {
    let actions: [Entry] = [("a", .neutral), ("b", .neutral), ("c", .neutral), ("d", .destructive)]
    #expect(ShadowRowActionLayout.trailing(actions, kind: \.kind).map(\.name) == ["d", "a", "b"])
  }

  @Test("should keep one reversible action on the leading edge")
  func leadingOnly() {
    let actions: [Entry] = [("delete", .destructive), ("read", .accent), ("flag", .warning)]
    #expect(ShadowRowActionLayout.leading(actions, kind: \.kind).map(\.name) == ["read"])
  }

  @Test("should list destructive actions last in the context menu")
  func menuOrder() {
    let leading: [Entry] = [("read", .accent)]
    let trailing: [Entry] = [("delete", .destructive), ("flag", .warning)]
    let menu = ShadowRowActionLayout.menu(leading: leading, trailing: trailing, kind: \.kind)
    #expect(menu.safe.map(\.name) == ["read", "flag"])
    #expect(menu.destructive.map(\.name) == ["delete"])
  }

  @Test("should map kinds to solid tokens")
  func tokens() {
    #expect(ShadowRowActionKind.accent.token == .accent)
    #expect(ShadowRowActionKind.warning.token == .warningSolid)
    #expect(ShadowRowActionKind.destructive.token == .dangerSolid)
    #expect(ShadowRowActionKind.neutral.token == .neutralSolid)
  }
}

@Suite("Notifications")
struct ShadowNotificationTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private static let locale = Locale(identifier: "en_US_POSIX")
  private static let now = Date(timeIntervalSince1970: 1_794_657_600)

  private func date(hoursAgo: Double) -> Date { Self.now.addingTimeInterval(-hoursAgo * 3600) }

  private func make(_ id: Int, hoursAgo: Double, isRead: Bool = false) -> ShadowNotification<Int> {
    ShadowNotification(id: id, title: "n\(id)", date: date(hoursAgo: hoursAgo), isRead: isRead)
  }

  @Test("should put same-day, previous-day and older dates in their buckets")
  func buckets() {
    let calendar = Self.calendar
    #expect(ShadowDayBucket(date: date(hoursAgo: 0.1), now: Self.now, calendar: calendar) == .today)
    #expect(ShadowDayBucket(date: date(hoursAgo: 13), now: Self.now, calendar: calendar) == .yesterday)
    #expect(ShadowDayBucket(date: date(hoursAgo: 24 * 4), now: Self.now, calendar: calendar) == .earlier)
  }

  @Test("should treat future dates as today")
  func future() {
    #expect(ShadowDayBucket(date: Self.now.addingTimeInterval(86_400 * 3), now: Self.now, calendar: Self.calendar) == .today)
  }

  @Test("should bucket on calendar days, not 24-hour windows")
  func midnight() {
    let justAfterMidnight = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 0, minute: 30))!
    let lateYesterday = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 23, minute: 50))!
    #expect(ShadowDayBucket(date: lateYesterday, now: justAfterMidnight, calendar: Self.calendar) == .yesterday)
  }

  @Test("should group newest first and omit empty buckets")
  func grouping() {
    let items = [make(1, hoursAgo: 30), make(2, hoursAgo: 1), make(3, hoursAgo: 24 * 5), make(4, hoursAgo: 2)]
    let groups = items.shadowGroupedByDay(now: Self.now, calendar: Self.calendar)
    #expect(groups.map(\.bucket) == [.today, .yesterday, .earlier])
    #expect(groups[0].notifications.map(\.id) == [2, 4])
    #expect(groups[1].notifications.map(\.id) == [1])
    #expect(groups[2].notifications.map(\.id) == [3])
  }

  @Test("should return no groups for an empty list")
  func empty() {
    let items: [ShadowNotification<Int>] = []
    #expect(items.shadowGroupedByDay(now: Self.now, calendar: Self.calendar).isEmpty)
  }

  @Test("should count unread notifications")
  func unread() {
    let items = [make(1, hoursAgo: 1), make(2, hoursAgo: 2, isRead: true), make(3, hoursAgo: 3)]
    #expect(items.shadowUnreadCount() == 2)
    #expect(([] as [ShadowNotification<Int>]).shadowUnreadCount() == 0)
  }

  @Test("should show weekday names for the last week and dates beyond")
  func relativeTime() {
    let calendar = Self.calendar
    let locale = Self.locale
    #expect(ShadowRelativeTime.string(for: date(hoursAgo: 13), now: Self.now, calendar: calendar, locale: locale) == "Fri")
    #expect(ShadowRelativeTime.string(for: date(hoursAgo: 24 * 5), now: Self.now, calendar: calendar, locale: locale) == "Mon")
    #expect(ShadowRelativeTime.string(for: date(hoursAgo: 24 * 20), now: Self.now, calendar: calendar, locale: locale) == "Oct 25")
    #expect(ShadowRelativeTime.string(for: date(hoursAgo: 24 * 400), now: Self.now, calendar: calendar, locale: locale).contains("2025"))
  }

  @Test("should format same-day times relative to now and never in the future")
  func sameDay() {
    let twoHours = ShadowRelativeTime.string(for: date(hoursAgo: 2), now: Self.now, calendar: Self.calendar, locale: Self.locale)
    #expect(twoHours.contains("2"))
    let future = ShadowRelativeTime.string(for: Self.now.addingTimeInterval(600), now: Self.now, calendar: Self.calendar, locale: Self.locale)
    #expect(future == "now")
  }
}

@Suite("Tree nodes")
struct ShadowTreeNodeTests {
  private let tree = ShadowTreeNode(
    id: "root", title: "Characters", systemImage: "folder",
    children: [
      ShadowTreeNode(id: "a", title: "The Archivist", systemImage: "folder", children: [ShadowTreeNode(id: "a1", title: "Secret", systemImage: "doc")]),
      ShadowTreeNode(id: "m", title: "Mira Vale", systemImage: "folder", children: []),
    ]
  )

  @Test("should count every descendant")
  func descendants() {
    #expect(tree.descendantCount == 3)
    #expect(tree.children?[1].descendantCount == 0)
  }

  @Test("should report depth including the node itself")
  func depth() {
    #expect(tree.depth == 3)
    #expect(tree.children?[0].children?[0].depth == 1)
  }

  @Test("should flatten depth first with levels")
  func flatten() {
    let flat = tree.flattened()
    #expect(flat.map(\.node.id) == ["root", "a", "a1", "m"])
    #expect(flat.map(\.level) == [0, 1, 2, 1])
  }

  @Test("should find nodes by id and distinguish leaves from empty folders")
  func lookup() {
    #expect(tree.node(withID: "a1")?.title == "Secret")
    #expect(tree.node(withID: "zzz") == nil)
    #expect(tree.node(withID: "a1")?.isLeaf == true)
    #expect(tree.node(withID: "m")?.isLeaf == false)
  }
}

@Suite("Text style tracking")
struct ShadowTextStyleTrackingTests {
  @Test("should not track any cross-platform role")
  func rolesUntracked() {
    let roles: [ShadowTextStyle] = [.largeTitle, .title, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption, .caption2]
    #expect(roles.allSatisfy { $0.tracking == 0 })
  }

  @Test("should keep tracking only on the explicit Mac section header")
  func sectionHeaderTracked() {
    #expect(ShadowTextStyle.macSubheadline.tracking > 0)
    #if os(macOS)
      #expect(ShadowTextStyle.sectionHeader == .macSubheadline)
    #endif
    #expect(ShadowTextStyle.allCases.filter { $0.tracking != 0 } == [.macSubheadline])
  }

  @Test("should set the Mac subheadline role as regular 11pt")
  func macSubheadlineRegular() {
    #if os(macOS)
      #expect(ShadowTextStyle.subheadline == .macFootnote)
      #expect(ShadowTextStyle.subheadline.weight == .regular)
    #endif
  }
}

@Suite("Notification layout")
struct ShadowNotificationLayoutTests {
  @Test("should give rows with any icon kind the same separator inset when the slot is reserved", arguments: ShadowDensity.allCases)
  func sameInset(density: ShadowDensity) {
    let metrics = ShadowListMetrics(density: density)
    let width = ShadowNotificationLayout.leadingWidth(reservesIconSlot: true, density: density)
    let icons: [ShadowNotificationIcon] = [.none, .symbol("bell"), .avatar(name: "Mira Vale")]
    let insets = icons.map { _ in metrics.separatorInset(leadingWidth: width) }
    #expect(Set(insets).count == 1)
  }

  @Test("should size the slot to the largest icon", arguments: ShadowDensity.allCases)
  func slotFitsIcons(density: ShadowDensity) {
    let metrics = ShadowListMetrics(density: density)
    let avatar = density == .touch ? ShadowAvatarSize.medium.diameter : ShadowAvatarSize.small.diameter
    #expect(ShadowNotificationLayout.iconSlotWidth(density: density) >= max(avatar, metrics.tileSize))
  }

  @Test("should drop the slot when no row has an icon")
  func noSlot() {
    #expect(ShadowNotificationLayout.leadingWidth(reservesIconSlot: false) == ShadowNotificationLayout.dotDiameter)
  }
}

@MainActor
@Suite("Grouped section")
struct ShadowGroupedSectionTests {
  private func separatorRows<Content: View>(_ content: Content) -> Int {
    let view = ShadowGroupedSection { content }.environment(\.displayScale, 1).frame(width: 320)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
    let bytesPerPixel = image.bitsPerPixel / 8
    func pixel(_ y: Int) -> [UInt8] {
      let offset = y * image.bytesPerRow + 250 * bytesPerPixel
      return (0..<3).map { bytes[offset + $0] }
    }
    let background = pixel(6)
    return (3..<(image.height - 3)).count { y in pixel(y) != background }
  }

  @Test("should draw one separator between two rows and none after the last")
  func betweenRows() {
    let two = separatorRows(
      Group {
        ShadowListRow(title: Text(verbatim: "One"))
        ShadowListRow(title: Text(verbatim: "Two"))
      })
    let one = separatorRows(ShadowListRow(title: Text(verbatim: "One")))
    #expect(one == 0)
    #expect(two == 1, "got \(two)")
  }

  @Test("should render Button-wrapped rows with and without a leading view")
  func buttonWrapped() {
    let section = ShadowGroupedSection {
      Button {
      } label: {
        ShadowListRow(title: Text(verbatim: "One"))
      }
      Button {
      } label: {
        ShadowListRow(title: Text(verbatim: "Two"), leading: { ShadowSymbolTile(systemImage: "bell") })
      }
    }
    #expect(ImageRenderer(content: section.buttonStyle(.shadowRow).frame(width: 320)).cgImage != nil)
  }
}
