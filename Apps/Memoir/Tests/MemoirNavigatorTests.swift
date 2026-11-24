import Foundation
import MemoirCore
import Testing

@testable import Memoir

@MainActor
@Suite("MemoirNavigator", TestTimeLimit.quick)
struct MemoirNavigatorTests {
  private static let detail = MemoirRoute.quest(.detail(UUID(uuidString: "0190f3a0-0000-7000-8000-000000000004")!))
  private static let expense = MemoirRoute.money(.expense(UUID(uuidString: "0190f3a0-0000-7000-8000-000000000005")!))

  private func selection(_ modules: Set<MemoirModule>) throws -> ModuleSelection {
    try ModuleSelection(modules)
  }

  @Test("should open the tab holding the sidebar's screen with that screen pushed", arguments: [MemoirDestination.settings, .ask, .quests, .sideQuests])
  func carriesPushedScreenToTabs(destination: MemoirDestination) {
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = destination

    navigator.layout = .tabs

    #expect(navigator.tab == destination.tab)
    #expect(navigator.paths[destination.tab] == [.destination(destination)])
  }

  @Test("should open a tab at its root when the sidebar shows that root", arguments: [MemoirDestination.today, .planningBoard, .money, .hero])
  func carriesRootToTabs(destination: MemoirDestination) {
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = destination
    navigator.paths[destination.tab] = [.destination(.settings)]

    navigator.layout = .tabs

    #expect(navigator.tab == destination.tab)
    #expect(navigator.paths[destination.tab] == [])
  }

  @Test("should show the top of the tab's stack in the sidebar")
  func carriesStackTopToSidebar() {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .today
    navigator.push(.history, in: .today)
    navigator.push(.ask, in: .today)

    navigator.layout = .sidebar

    #expect(navigator.selection == .ask)
  }

  @Test("should show the tab's root in the sidebar when nothing is pushed, and Log's first screen for Log")
  func carriesTabRootToSidebar() {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .money

    navigator.layout = .sidebar

    #expect(navigator.selection == .money)

    navigator.layout = .tabs
    navigator.tab = .log
    navigator.layout = .sidebar

    #expect(navigator.selection == .journal)
  }

  @Test("should keep the place through a round trip of layouts")
  func keepsPlaceThroughRoundTrip() {
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = .weeklyReview

    navigator.layout = .tabs
    navigator.layout = .sidebar

    #expect(navigator.selection == .weeklyReview)
  }

  @Test("should leave the place alone when the layout is set to the one it has")
  func ignoresSameLayout() {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .plan
    navigator.push(.quests, in: .plan)
    navigator.selection = .hero

    navigator.layout = .tabs

    #expect(navigator.tab == .plan)
    #expect(navigator.paths[.plan] == [.destination(.quests)])
  }

  @Test("should carry the details pushed in the sidebar onto the tab's stack and back")
  func carriesDetailsBetweenLayouts() {
    let quest = MemoirRoute.quest(.detail(UUID(uuidString: "0190f3a0-0000-7000-8000-000000000001")!))
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = .quests
    navigator.detailPath = [quest]

    navigator.layout = .tabs

    #expect(navigator.tab == .plan)
    #expect(navigator.paths[.plan] == [.destination(.quests), quest])

    navigator.layout = .sidebar

    #expect(navigator.selection == .quests)
    #expect(navigator.detailPath == [quest])
  }

  @Test("should keep a tab root's details when it moves to the sidebar")
  func carriesRootDetailsToSidebar() {
    let quest = MemoirRoute.quest(.detail(UUID(uuidString: "0190f3a0-0000-7000-8000-000000000002")!))
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .today
    navigator.paths[.today] = [quest]

    navigator.layout = .sidebar

    #expect(navigator.selection == .today)
    #expect(navigator.detailPath == [quest])
  }

  @Test("should clear the sidebar's details when another screen is selected")
  func clearsDetailsOnSelection() {
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = .quests
    navigator.detailPath = [.quest(.detail(UUID(uuidString: "0190f3a0-0000-7000-8000-000000000003")!))]

    navigator.selection = .money

    #expect(navigator.detailPath.isEmpty)
  }

  @Test("should open the first screen and tab the modules show, and place nothing when the first layout arrives")
  func opensAtFirstShownPlace() throws {
    let money = MemoirNavigator(modules: try selection([.money]))
    #expect(money.selection == .money)
    #expect(money.tab == .money)

    let body = MemoirNavigator(modules: try selection([.body, .money]))
    body.layout = .tabs

    #expect(body.tab == .log)
    #expect(body.paths[.log, default: []].isEmpty)
  }

  @Test("should fall back to the first shown screen when the sidebar's screen is hidden, dropping its details")
  func fallsBackInSidebar() throws {
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = .quests
    navigator.detailPath = [Self.detail]

    navigator.modules = try selection([.money, .hero])

    #expect(navigator.selection == .money)
    #expect(navigator.detailPath.isEmpty)
  }

  @Test("should keep the sidebar's screen and drop only the hidden details above it")
  func keepsShownScreenInSidebar() throws {
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = .history
    navigator.detailPath = [.reflect(.record("quest")), Self.expense, Self.detail]

    navigator.modules = try selection([.money])

    #expect(navigator.selection == .history)
    #expect(navigator.detailPath == [.reflect(.record("quest")), Self.expense])
  }

  @Test("should move a hidden Today's stack to the tab now holding its screen")
  func movesHiddenTabStack() throws {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .today
    navigator.push(.settings, in: .today)
    navigator.paths[.today, default: []].append(.settings(.about))

    navigator.modules = try selection([.money])

    #expect(navigator.tab == .money)
    #expect(navigator.paths[.money] == [.destination(.settings), .settings(.about)])
    #expect(navigator.paths[.today] == nil)
  }

  @Test("should open the first tab at its root when the hidden tab held only hidden places")
  func fallsBackToFirstTab() throws {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .plan
    navigator.paths[.plan] = [.destination(.quests), Self.detail]
    navigator.paths[.money] = [Self.expense]

    navigator.modules = try selection([.money, .hero])

    #expect(navigator.tab == .money)
    #expect(navigator.paths[.money] == [Self.expense])
    #expect(navigator.paths[.plan] == nil)
  }

  @Test("should keep the Log list in place when another device hides one of its screens")
  func keepsListingRoot() throws {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .log

    navigator.modules = try selection([.meals, .body, .money])

    #expect(navigator.tab == .log)
    #expect(navigator.paths[.log, default: []].isEmpty)
  }

  @Test("should keep the screen on show as Log's root changes under it")
  func keepsScreenAsLogRootChanges() throws {
    let navigator = MemoirNavigator(layout: .tabs, modules: try selection([.journal, .meals, .money]))
    navigator.tab = .log
    navigator.push(.journal, in: .log)

    navigator.modules = try selection([.journal, .money])

    #expect(navigator.map.root(of: .log) == .journal)
    #expect(navigator.paths[.log, default: []].isEmpty)

    navigator.modules = try selection([.journal, .meals, .money])

    #expect(navigator.map.root(of: .log) == nil)
    #expect(navigator.paths[.log] == [.destination(.journal)])
  }

  @Test("should drop a push of a hidden place, so a stale link does nothing")
  func dropsHiddenPush() throws {
    let navigator = MemoirNavigator(layout: .tabs, modules: try selection([.money]))
    navigator.push(.history, in: .money)

    navigator.paths[.money, default: []].append(.destination(.today))
    navigator.paths[.money, default: []].append(Self.detail)
    navigator.paths[.plan] = [.destination(.quests)]

    #expect(navigator.paths[.money] == [.destination(.history)])
    #expect(navigator.paths[.plan] == nil)

    navigator.layout = .sidebar
    navigator.detailPath.append(.hero(.comingBack))

    #expect(navigator.selection == .history)
    #expect(navigator.detailPath.isEmpty)
  }

  @Test("should carry a place hidden while in the sidebar over to the tabs at the first shown tab")
  func carriesFallbackToTabs() throws {
    let navigator = MemoirNavigator(layout: .sidebar)
    navigator.selection = .quests

    navigator.modules = try selection([.money, .hero])
    navigator.layout = .tabs

    #expect(navigator.tab == .money)
    #expect(navigator.paths[.money, default: []].isEmpty)
  }

  @Test("should carry Settings moved off a hidden Today back to the sidebar")
  func carriesMovedSettingsToSidebar() throws {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .today
    navigator.push(.settings, in: .today)

    navigator.modules = try selection([.money, .hero])
    navigator.layout = .sidebar

    #expect(navigator.selection == .settings)

    navigator.layout = .tabs

    #expect(navigator.tab == .money)
    #expect(navigator.paths[.money] == [.destination(.settings)])
  }

  @Test("should leave the place alone when the modules are set to the ones it has")
  func ignoresSameModules() {
    let navigator = MemoirNavigator(layout: .tabs)
    navigator.tab = .plan
    navigator.push(.quests, in: .plan)

    navigator.modules = .all

    #expect(navigator.tab == .plan)
    #expect(navigator.paths[.plan] == [.destination(.quests)])
  }
}
