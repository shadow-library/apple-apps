import Foundation
import MemoirCore
import SwiftUI
import Testing

@testable import Memoir

@Suite("MemoirDestination", TestTimeLimit.quick)
struct MemoirNavigationTests {
  private static let reflect: [MemoirDestination] = [.history, .insights, .weeklyReview, .ask]

  /// Every selection `ModuleSelection` accepts.
  private static let selections: [ModuleSelection] = (0..<(1 << MemoirModule.allCases.count)).compactMap { mask in
    let modules = MemoirModule.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
    return try? ModuleSelection(Set(modules))
  }

  private static func sectionDestinations(_ section: MemoirSection) -> [MemoirDestination] {
    MemoirDestination.allCases.filter { $0.section == section }
  }

  private static func reached(from entry: MemoirToolbarEntry) -> [MemoirDestination] {
    switch entry {
    case .link(let destination): [destination]
    case .menu(_, let destinations): destinations
    }
  }

  private func map(_ modules: Set<MemoirModule>) throws -> MemoirNavigationMap {
    MemoirNavigationMap(try ModuleSelection(modules))
  }

  @Test("should group the sidebar as the reference does: Day, Capture, Reflect, then Hero and Settings")
  func groupsSidebar() {
    #expect(MemoirSection.allCases == [.day, .capture, .reflect, .footer])
    #expect(MemoirNavigationMap.all.sections == MemoirSection.allCases)
    #expect(MemoirNavigationMap.all.destinations(in: .day) == [.today, .planningBoard, .quests])
    #expect(MemoirNavigationMap.all.destinations(in: .capture) == [.journal, .meals, .weight, .bodyAndHealth, .sideQuests, .money])
    #expect(MemoirNavigationMap.all.destinations(in: .reflect) == Self.reflect)
    #expect(MemoirNavigationMap.all.destinations(in: .footer) == [.hero, .settings])
    #expect(MemoirSection.footer.title == nil)
  }

  @Test("should list every destination in exactly one sidebar section")
  func coversEveryDestinationOnce() {
    let listed = MemoirSection.allCases.flatMap(Self.sectionDestinations)
    #expect(listed.count == MemoirDestination.allCases.count)
    #expect(Set(listed) == Set(MemoirDestination.allCases))
  }

  @Test("should order the iPhone tabs Today, Plan, Log, Money, Hero with their roots")
  func ordersTabs() {
    #expect(MemoirTab.allCases == [.today, .plan, .log, .money, .hero])
    #expect(MemoirNavigationMap.all.tabs == MemoirTab.allCases)
    #expect(MemoirNavigationMap.all.showsTabBar)
    #expect(MemoirTab.allCases.map(MemoirNavigationMap.all.root) == [.today, .planningBoard, nil, .money, .hero])
  }

  @Test("should put Reflect in one menu and Settings beside it on Today's toolbar")
  func buildsTodayToolbar() {
    #expect(MemoirNavigationMap.all.toolbar(of: .today) == [.menu(.reflect, Self.reflect), .link(.settings)])
  }

  @Test("should put Quests on Plan's toolbar and list every capture screen at Log's root")
  func buildsOtherTabs() {
    let map = MemoirNavigationMap.all
    #expect(map.toolbar(of: .plan) == [.link(.quests)])
    #expect(map.toolbar(of: .log).isEmpty)
    #expect(map.listed(in: .log) == [.journal, .meals, .weight, .bodyAndHealth, .sideQuests])
    #expect(map.toolbar(of: .money).isEmpty)
    #expect(map.toolbar(of: .hero).isEmpty)
  }

  @Test("should show the reference's labels")
  func showsReferenceLabels() {
    let titles = MemoirDestination.allCases.map { String(localized: $0.title) }
    #expect(
      titles == [
        "Today", "Planning Board", "Quests", "Journal", "Meals", "Weight", "Body & health", "Side quests", "Money", "History", "Insights", "Weekly Review", "Ask", "Hero",
        "Settings",
      ])
    #expect(MemoirTab.allCases.map { String(localized: MemoirNavigationMap.all.title(of: $0)) } == ["Today", "Plan", "Log", "Money", "Hero"])
    #expect(MemoirSection.allCases.compactMap { $0.title.map { String(localized: $0) } } == ["Day", "Capture", "Reflect"])
  }

  @Test("should map a size class to the tab bar only when compact")
  func mapsLayout() {
    #expect(MemoirLayout(sizeClass: .compact) == .tabs)
    #expect(MemoirLayout(sizeClass: .regular) == .sidebar)
    #expect(MemoirLayout(sizeClass: nil) == .sidebar)
  }

  @Test("should show Money alone as the root without a tab bar, with Reflect and Settings on its toolbar")
  func showsMoneyOnly() throws {
    let map = try map([.money])

    #expect(map.destinations == [.money] + Self.reflect + [.settings])
    #expect(map.sections == [.capture, .reflect, .footer])
    #expect(map.tabs == [.money])
    #expect(!map.showsTabBar)
    #expect(map.root(of: .money) == .money)
    #expect(map.toolbar(of: .money) == [.menu(.reflect, Self.reflect), .link(.settings)])
    #expect(map.tab(of: .settings) == .money)
    #expect(map.firstDestination == .money)
  }

  @Test("should root a lone capture module at its screen, named after it, without Weekly Review", arguments: [MemoirModule.journal, .meals])
  func showsOneCaptureScreen(module: MemoirModule) throws {
    let map = try map([module])
    let screen: MemoirDestination = module == .journal ? .journal : .meals

    #expect(map.tabs == [.log])
    #expect(!map.showsTabBar)
    #expect(map.root(of: .log) == screen)
    #expect(map.listed(in: .log).isEmpty)
    #expect(String(localized: map.title(of: .log)) == String(localized: screen.title))
    #expect(map.systemImage(of: .log) == screen.systemImage)
    #expect(map.toolbar(of: .log) == [.menu(.reflect, [.history, .insights, .ask]), .link(.settings)])
    #expect(!map.shows(.weeklyReview))
    #expect(map.sections == [.capture, .reflect, .footer])
  }

  @Test("should list Weight and Body & health at Log's root for Body alone, with Reflect and Settings on its toolbar")
  func showsBodyOnly() throws {
    let map = try map([.body])

    #expect(map.tabs == [.log])
    #expect(map.root(of: .log) == nil)
    #expect(map.listed(in: .log) == [.weight, .bodyAndHealth])
    #expect(map.toolbar(of: .log) == [.menu(.reflect, [.history, .insights, .ask]), .link(.settings)])
    #expect(String(localized: map.title(of: .log)) == "Log")
  }

  @Test("should keep Today, Plan and Hero for quests alone, with Side quests as Log's root and no Money")
  func showsQuestsOnly() throws {
    let map = try map([.quests, .hero])

    #expect(map.tabs == [.today, .plan, .log, .hero])
    #expect(map.root(of: .log) == .sideQuests)
    #expect(map.toolbar(of: .today) == [.menu(.reflect, Self.reflect), .link(.settings)])
    #expect(map.toolbar(of: .plan) == [.link(.quests)])
    #expect(!map.shows(.money) && !map.shows(.journal) && !map.shows(.weight))
    #expect(map.sections == MemoirSection.allCases)
  }

  @Test("should reach Settings, Ask and History from Money's toolbar when Money and Hero show without quests")
  func showsMoneyAndHero() throws {
    let map = try map([.money, .hero])

    #expect(map.tabs == [.money, .hero])
    #expect(map.showsTabBar)
    #expect(!map.shows(.today) && !map.shows(.planningBoard) && !map.shows(.quests) && !map.shows(.sideQuests))
    #expect(map.toolbar(of: .money) == [.menu(.reflect, Self.reflect), .link(.settings)])
    #expect(map.toolbar(of: .hero).isEmpty)
    for destination in [MemoirDestination.settings, .ask, .history, .insights, .weeklyReview] { #expect(map.tab(of: destination) == .money) }
    #expect(map.destinations(in: .footer) == [.hero, .settings])
  }

  @Test("should reach every shown destination from exactly one tab and no hidden one, for every valid selection")
  func reachesShownDestinationsOnce() {
    #expect(Self.selections.count > 1)
    for selection in Self.selections {
      let map = MemoirNavigationMap(selection)
      let reached = map.tabs.flatMap { tab in (map.root(of: tab).map { [$0] } ?? []) + map.listed(in: tab) + map.toolbar(of: tab).flatMap(Self.reached) }
      #expect(reached.count == map.destinations.count, "\(selection.modules)")
      #expect(Set(reached) == Set(map.destinations), "\(selection.modules)")
      #expect(map.shows(.settings) && map.shows(.history) && map.shows(.insights) && map.shows(.ask))
      for destination in map.destinations { #expect(map.shows(tab: map.tab(of: destination))) }
    }
  }

  @Test("should list in the sidebar only the shown destinations, in its order, without an empty section, for every valid selection")
  func listsShownSections() {
    for selection in Self.selections {
      let map = MemoirNavigationMap(selection)
      let listed = map.sections.flatMap(map.destinations(in:))
      #expect(listed == MemoirSection.allCases.flatMap(Self.sectionDestinations).filter(map.shows))
      #expect(map.sections.allSatisfy { !map.destinations(in: $0).isEmpty })
      #expect(map.firstDestination == listed.first)
    }
  }

  @Test("should show Weekly Review with quests or money only")
  func showsWeeklyReview() throws {
    #expect(try map([.money]).shows(.weeklyReview))
    #expect(try map([.quests, .hero]).shows(.weeklyReview))
    #expect(try !map([.journal, .meals, .body]).shows(.weeklyReview))
  }

  @Test("should hide an area's details with its module and keep Settings' always")
  func gatesRoutes() throws {
    let money = try map([.money])
    let id = UUID(uuidString: "0190f3a0-0000-7000-8000-000000000010")!

    #expect(money.shows(.money(.expense(id))))
    #expect(!money.shows(.quest(.detail(id))))
    #expect(!money.shows(.hero(.comingBack)))
    #expect(!money.shows(.destination(.today)))
    #expect(money.shows(.settings(.about)))
    #expect(money.shows(.reflect(.record("expense"))))
    #expect(try !map([.journal]).shows(.money(.subscriptions)))
    #expect(try map([.money, .hero]).shows(.hero(.comingBack)))
  }

  @Test("should keep a path up to its first hidden place")
  func keepsPathUpToHiddenPlace() throws {
    let money = try map([.money])
    let id = UUID(uuidString: "0190f3a0-0000-7000-8000-000000000011")!

    #expect(money.kept([.destination(.history), .money(.expense(id)), .destination(.quests), .settings(.about)]) == [.destination(.history), .money(.expense(id))])
    #expect(money.stack([.destination(.money), .money(.expense(id))], in: .money) == [.money(.expense(id))])
  }

  @Test("should name every capture screen in Log's footer only while all of them are listed")
  func namesOnlyListedScreensInFooter() throws {
    let full = String(localized: LogHub.footer(listing: MemoirNavigationMap.all.listed(in: .log)))
    let partial = String(localized: LogHub.footer(listing: try map([.body]).listed(in: .log)))

    #expect(full == "Journal, meals, weight, the manual health metrics and side quests. Each entry is meant to take under ten seconds.")
    #expect(partial == "Each entry is meant to take under ten seconds.")
    #expect(String(localized: LogHub.footer(listing: try map([.journal, .meals, .body]).listed(in: .log))) == partial)
  }
}
