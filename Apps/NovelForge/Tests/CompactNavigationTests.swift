import Foundation
import SwiftUI
import Testing

@testable import NovelForge

@MainActor
@Suite("Compact navigation", TestTimeLimit.standard)
struct CompactNavigationTests {
  private struct Route: Hashable {
    let id: Int
  }

  @Test("should choose the compact layout only for a compact horizontal size class")
  func choosesLayout() {
    #expect(NovelLayout(sizeClass: .compact) == .compact)
    #expect(NovelLayout(sizeClass: .regular) == .regular)
    #expect(NovelLayout(sizeClass: nil) == .regular)
  }

  @Test("should open a novel on its chat in the compact layout")
  func opensOnChat() {
    let navigator = NovelNavigator(layout: .compact)
    #expect(navigator.section == .chat)
    #expect(navigator.compactPath.isEmpty)
    #expect(navigator.isAtRoot(.chat))
  }

  @Test("should push the reader onto the chat stack and come back to the chat")
  func pushesReader() {
    let navigator = NovelNavigator(layout: .compact)
    navigator.show(.reader)
    #expect(navigator.section == .reader)
    #expect(navigator.compactPath.count == 1)

    navigator.push(ReaderRoute.chapter(3))
    #expect(navigator.compactPath.count == 2)
    #expect(!navigator.isAtRoot(.reader))

    navigator.pop(.reader)
    #expect(navigator.isAtRoot(.reader))
    #expect(navigator.compactPath.count == 1)

    navigator.compactBinding.wrappedValue.removeLast()
    #expect(navigator.section == .chat)
    #expect(navigator.compactPath.isEmpty)
  }

  @Test("should deep link to a chapter with the reader and the chat beneath it")
  func deepLinksToChapter() {
    let navigator = NovelNavigator(layout: .compact)
    navigator.open(.reader, ReaderRoute.chapter(7))
    #expect(navigator.section == .reader)
    #expect(navigator.compactPath.count == 2)

    navigator.open(.reader, ReaderRoute.chapter(8))
    #expect(navigator.compactPath.count == 2)
  }

  @Test("should show each more item one level above the chat and replace it when another is chosen")
  func showsMoreItems() {
    let navigator = NovelNavigator(layout: .compact)
    for section in [NovelSection.story, .storyBible, .notebook, .overview] {
      navigator.show(section)
      #expect(navigator.section == section)
      #expect(navigator.compactPath.count == 1)
    }
  }

  @Test("should keep the depth when the section already shown is shown again and reset it for the chat")
  func showsSameSection() {
    let navigator = NovelNavigator(layout: .compact)
    navigator.open(.story, Route(id: 1))
    navigator.show(.story)
    #expect(navigator.compactPath.count == 2)

    navigator.push(CompactStop.pending)
    navigator.show(.chat)
    #expect(navigator.compactPath.isEmpty)
    navigator.push(CompactStop.pending)
    navigator.show(.chat)
    #expect(navigator.compactPath.isEmpty)
  }

  @Test("should open a chapter above waiting on you and come back to it with the chat's section")
  func opensAboveWaitingOnYou() {
    let navigator = NovelNavigator(layout: .compact)
    navigator.push(CompactStop.pending)
    navigator.openAbove(.reader, ReaderRoute.chapter(4))
    #expect(navigator.section == .reader && navigator.compactPath.count == 3)
    #expect(!navigator.isAtRoot(.reader))

    navigator.pop(.reader)
    #expect(navigator.isAtRoot(.reader) && navigator.compactPath.count == 2)
    navigator.pop(.reader)
    #expect(navigator.compactPath.count == 2)

    navigator.compactBinding.wrappedValue.removeLast()
    #expect(navigator.section == .chat && navigator.compactPath.count == 1 && navigator.isAtRoot(.chat) == false)

    navigator.compactBinding.wrappedValue.removeLast()
    #expect(navigator.section == .chat && navigator.compactPath.isEmpty)
    navigator.show(.reader)
    #expect(navigator.section == .reader && navigator.compactPath.count == 1 && navigator.isAtRoot(.reader))
    navigator.push(ReaderRoute.chapter(2))
    navigator.pop(.reader)
    #expect(navigator.compactPath.count == 1)
  }

  @Test("should show the chapters from the bar after coming back from a chapter opened above waiting on you")
  func showsChaptersAfterComingBack() {
    let navigator = NovelNavigator(layout: .compact)
    navigator.push(CompactStop.pending)
    navigator.openAbove(.reader, ReaderRoute.chapter(4))
    navigator.compactBinding.wrappedValue = NavigationPath([CompactStop.pending])
    #expect(navigator.section == .chat)

    navigator.show(.reader)
    #expect(navigator.section == .reader && navigator.compactPath.count == 1 && navigator.isAtRoot(.reader))
    navigator.compactBinding.wrappedValue.removeLast()
    #expect(navigator.section == .chat && navigator.compactPath.isEmpty)
  }

  @Test("should open above as a plain deep link in the regular layout")
  func opensAboveInRegular() {
    let navigator = NovelNavigator()
    navigator.open(.reader, ReaderRoute.chapter(1))
    navigator.push(ReaderRoute.versions(1))
    navigator.show(.chat)
    navigator.openAbove(.reader, ReaderRoute.chapter(4))
    #expect(navigator.section == .reader && navigator.path(for: .reader).wrappedValue.count == 1 && navigator.compactPath.isEmpty)
  }

  @Test("should ignore a pop at the root or for a section that is not shown")
  func ignoresPops() {
    let navigator = NovelNavigator(layout: .compact)
    navigator.pop(.chat)
    navigator.show(.reader)
    navigator.pop(.reader)
    navigator.pop(.story)
    #expect(navigator.compactPath.count == 1)
    #expect(navigator.isAtRoot(.story))
  }

  @Test("should keep the section across a size class change and drop only the routes above it")
  func keepsSectionAcrossLayouts() {
    let navigator = NovelNavigator()
    navigator.open(.story, Route(id: 1))
    navigator.layout = .compact
    #expect(navigator.section == .story)
    #expect(navigator.compactPath.count == 1)
    #expect(navigator.paths[.story] == nil)

    navigator.push(Route(id: 2))
    navigator.layout = .regular
    #expect(navigator.section == .story)
    #expect(navigator.compactPath.isEmpty)
    #expect(navigator.path(for: .story).wrappedValue.isEmpty)
  }

  @Test("should open the chat when an untouched novel turns compact and keep a chosen section")
  func untouchedTurnsToChat() {
    let untouched = NovelNavigator()
    #expect(untouched.section == .overview)
    untouched.layout = .compact
    #expect(untouched.section == .chat)

    let chosen = NovelNavigator()
    chosen.show(.overview)
    chosen.layout = .compact
    #expect(chosen.section == .overview)
  }

  @Test("should show the selection list's chat when the section was cleared")
  func clearedSectionFallsBackToChat() {
    let navigator = NovelNavigator()
    navigator.section = nil
    navigator.layout = .compact
    #expect(navigator.section == .chat)
  }

  @Test("should leave the regular layout on the section paths")
  func regularKeepsPaths() {
    let navigator = NovelNavigator()
    navigator.open(.reader, Route(id: 1))
    navigator.push(Route(id: 2))
    #expect(navigator.path(for: .reader).wrappedValue.count == 2)
    #expect(navigator.compactPath.isEmpty)
    #expect(!navigator.isAtRoot(.reader))
  }

  @Test("should apply the layout to every navigator and to those made later")
  func navigatorsShareLayout() {
    let navigators = NovelNavigators()
    let first = UUID()
    navigators.navigator(for: first).show(.story)
    navigators.layout = .compact
    #expect(navigators.navigator(for: first).layout == .compact)
    #expect(navigators.navigator(for: first).section == .story)

    let later = navigators.navigator(for: UUID())
    #expect(later.layout == .compact)
    #expect(later.section == .chat)
  }
}
