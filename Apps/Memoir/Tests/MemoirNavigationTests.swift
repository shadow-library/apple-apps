import Foundation
import SwiftUI
import Testing

@testable import Memoir

@Suite("MemoirDestination", TestTimeLimit.quick)
struct MemoirNavigationTests {
  @Test("should group the sidebar as the reference does: Day, Capture, Reflect, then Hero and Settings")
  func groupsSidebar() {
    #expect(MemoirSection.allCases == [.day, .capture, .reflect, .footer])
    #expect(MemoirSection.day.destinations == [.today, .planningBoard, .quests])
    #expect(MemoirSection.capture.destinations == [.journal, .meals, .weight, .bodyAndHealth, .sideQuests, .money])
    #expect(MemoirSection.reflect.destinations == [.history, .insights, .weeklyReview, .ask])
    #expect(MemoirSection.footer.destinations == [.hero, .settings])
    #expect(MemoirSection.footer.title == nil)
  }

  @Test("should list every destination in exactly one sidebar section")
  func coversEveryDestinationOnce() {
    let listed = MemoirSection.allCases.flatMap(\.destinations)
    #expect(listed.count == MemoirDestination.allCases.count)
    #expect(Set(listed) == Set(MemoirDestination.allCases))
  }

  @Test("should order the iPhone tabs Today, Plan, Log, Money, Hero with their roots")
  func ordersTabs() {
    #expect(MemoirTab.allCases == [.today, .plan, .log, .money, .hero])
    #expect(MemoirTab.allCases.map(\.root) == [.today, .planningBoard, nil, .money, .hero])
  }

  @Test("should reach every destination on iPhone from exactly one tab")
  func reachesEveryDestinationFromOneTab() {
    let reachable = MemoirTab.allCases.flatMap { tab in (tab.root.map { [$0] } ?? []) + tab.pushed }
    #expect(reachable.count == MemoirDestination.allCases.count)
    #expect(Set(reachable) == Set(MemoirDestination.allCases))
    for destination in MemoirDestination.allCases {
      #expect(destination.tab.root == destination || destination.tab.pushed.contains(destination))
    }
  }

  @Test("should put Reflect in one menu and Settings beside it on Today's toolbar")
  func buildsTodayToolbar() {
    #expect(MemoirTab.today.toolbar == [.menu(.reflect, [.history, .insights, .weeklyReview, .ask]), .link(.settings)])
  }

  @Test("should put Quests on Plan's toolbar and list every capture screen at Log's root")
  func buildsOtherTabs() {
    #expect(MemoirTab.plan.toolbar == [.link(.quests)])
    #expect(MemoirTab.log.toolbar.isEmpty)
    #expect(MemoirTab.log.pushed == [.journal, .meals, .weight, .bodyAndHealth, .sideQuests])
    #expect(MemoirTab.money.toolbar.isEmpty)
    #expect(MemoirTab.hero.toolbar.isEmpty)
  }

  @Test("should show the reference's labels")
  func showsReferenceLabels() {
    let titles = MemoirDestination.allCases.map { String(localized: $0.title) }
    #expect(
      titles == [
        "Today", "Planning Board", "Quests", "Journal", "Meals", "Weight", "Body & health", "Side quests", "Money", "History", "Insights", "Weekly Review", "Ask", "Hero",
        "Settings",
      ])
    #expect(MemoirTab.allCases.map { String(localized: $0.title) } == ["Today", "Plan", "Log", "Money", "Hero"])
    #expect(MemoirSection.allCases.compactMap { $0.title.map { String(localized: $0) } } == ["Day", "Capture", "Reflect"])
  }

  @Test("should map a size class to the tab bar only when compact")
  func mapsLayout() {
    #expect(MemoirLayout(sizeClass: .compact) == .tabs)
    #expect(MemoirLayout(sizeClass: .regular) == .sidebar)
    #expect(MemoirLayout(sizeClass: nil) == .sidebar)
  }
}
