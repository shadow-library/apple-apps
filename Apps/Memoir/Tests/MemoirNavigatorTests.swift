import Foundation
import Testing

@testable import Memoir

@MainActor
@Suite("MemoirNavigator", TestTimeLimit.quick)
struct MemoirNavigatorTests {
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
}
