import Foundation
import NovelForgeCore
import SwiftUI
import Testing

@testable import NovelForge

@MainActor
@Suite("Overview deep links")
struct OverviewDeepLinkTests {
  private func tile(_ derived: Derived<Int>, deepLink: (Int) -> StatTile.Opening?) -> StatTile {
    StatTile(Text(verbatim: "Next"), derived, opens: .reader, deepLink: deepLink, value: { Text(verbatim: "\($0)") })
  }

  @Test("should open the route of the value when it is available")
  func opensRoute() {
    let navigator = NovelNavigator()
    let tile = tile(.available(7)) { .route(.reader, ReaderRoute.chapter($0)) }

    tile.opening?.perform(navigator)

    #expect(navigator.section == .reader)
    #expect(navigator.paths[.reader]?.count == 1)
  }

  @Test("should fall back to the section when the value is unavailable or has no route")
  func fallsBackToSection() {
    let navigator = NovelNavigator()
    tile(.unavailable([])) { .route(.reader, ReaderRoute.chapter($0)) }.opening?.perform(navigator)
    #expect(navigator.section == .reader)
    #expect(navigator.paths[.reader]?.isEmpty != false)

    let other = NovelNavigator()
    tile(.available(1)) { _ in nil }.opening?.perform(other)
    #expect(other.section == .reader)
    #expect(other.paths[.reader]?.isEmpty != false)
  }

  @Test("should replace the section's path with the route rather than stack on it")
  func replacesPath() {
    let navigator = NovelNavigator()
    navigator.open(.story, StoryRoute.volume("a"))

    StatTile.Opening.route(.story, StoryRoute.volume("b")).perform(navigator)

    #expect(navigator.paths[.story]?.count == 1)
  }
}
