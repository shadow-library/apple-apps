import ShadowDesignSystem
import SwiftUI

struct CommandPalettePage: View {
  @State private var isPresented = false
  @State private var toasts = ShadowToastCenter()
  @State private var query = "glass"
  @State private var emptyQuery = ""
  @State private var missingQuery = "synapse budget"
  @State private var searchText = "glass"
  @Environment(\.catalogPresentsSample) private var presentsSample

  private var sections: [ShadowCommandSection] { CommandPaletteDemo.sections(toasts: toasts) }

  var body: some View {
    ComponentPage(component: .commandPalette) {
      if DemoPlatform.opensDetail && presentsSample {
        livePalettePage
      } else if DemoPlatform.opensDetail {
        palettePages
      } else {
        searchTabPages
      }
    }
    .shadowCommandPalette(
      isPresented: $isPresented, sections: sections, prompt: "Search chapters and commands", emptyTitle: "No matches", shortcutTitle: "Open command palette",
      focusesSearchOnPresent: !presentsSample
    )
    .shadowToastPresenter(toasts)
    .catalogAutoPresent { if DemoPlatform.opensDetail { isPresented = true } }
  }

  private var livePalettePage: some View {
    StateSection("Palette", note: "⌘K opens the live palette over the page; recent items rank first.") {
      PresentationBackdrop(minHeight: 640, alignment: .top) {
        Button("Open command palette", systemImage: "command") { isPresented = true }
          .buttonStyle(.shadowGlass)
      }
    }
  }

  @ViewBuilder
  private var palettePages: some View {
    StateSection(
      "Palette",
      note: "⌘K opens a centred glass panel. ↑ and ↓ move the selection, Return runs it, Escape closes. Matching characters are highlighted; shortcuts trail."
    ) {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Button("Open command palette", systemImage: "command") { isPresented = true }
          .buttonStyle(.shadowBordered)
          .help("Open command palette (⌘K)")
        PresentationBackdrop(minHeight: 360, alignment: .top) {
          ShadowCommandPalette(
            sections: sections, query: $query, prompt: "Search chapters and commands", emptyTitle: "No matches", focusesSearchOnAppear: false, onClose: {})
        }
      }
    }
    StateSection("Before typing", note: "Recent items rank first, then commands and pages.") {
      PresentationBackdrop(minHeight: ShadowDensity.current == .touch ? 600 : 420, alignment: .top) {
        ShadowCommandPalette(
          sections: sections, query: $emptyQuery, prompt: "Search chapters and commands", emptyTitle: "No matches", focusesSearchOnAppear: false, onClose: {})
      }
    }
    StateSection("No matches", note: "The palette says so plainly and keeps the query for editing.") {
      PresentationBackdrop(minHeight: 220, alignment: .top) {
        ShadowCommandPalette(
          sections: sections, query: $missingQuery, prompt: "Search chapters and commands", emptyTitle: "No matches", focusesSearchOnAppear: false, onClose: {})
      }
    }
  }

  @ViewBuilder
  private var searchTabPages: some View {
    StateSection("Search tab", note: "iPhone has no palette: the Search tab lists matching content and commands with the same ranking.") {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ShadowSearchField("Search chapters and commands", text: $searchText, clearLabel: "Clear search")
        if ShadowCommandFilter.sections(sections, matching: searchText).isEmpty {
          ShadowContentUnavailable("No matches", kind: .noResults, message: "Try a chapter title or a command name.")
        } else {
          ShadowGroupedSection {
            ShadowCommandSearchResults(sections: sections, query: searchText)
          }
        }
      }
    }
    StateSection("Before typing", note: "Recent items first, then commands and pages.") {
      ShadowGroupedSection {
        ShadowCommandSearchResults(sections: Array(sections.prefix(2)), query: "")
      }
    }
    StateSection("No matches") {
      ShadowContentUnavailable("No matches", kind: .noResults, message: "Try a chapter title or a command name.")
    }
  }
}

enum CommandPaletteDemo {
  static func sections(toasts: ShadowToastCenter) -> [ShadowCommandSection] {
    let run: @MainActor @Sendable (String) -> Void = { title in toasts.show(ShadowToast("Opened \(title)", systemImage: "arrow.up.forward.app")) }
    func command(_ id: String, _ title: String, subtitle: String? = nil, systemImage: String, shortcut: KeyboardShortcut? = nil, keywords: [String] = [])
      -> ShadowCommand
    {
      ShadowCommand(id: id, title: title, subtitle: subtitle, systemImage: systemImage, shortcut: shortcut, keywords: keywords) { run(title) }
    }
    return [
      ShadowCommandSection(
        id: "recent", title: String(localized: "Recent"),
        commands: [
          command("chapter-42", String(localized: "Chapter 42 · The Glass Stair"), systemImage: "book"),
          command("chapter-41", String(localized: "Chapter 41 · Ink and Salt"), systemImage: "book"),
        ]),
      ShadowCommandSection(
        id: "commands", title: String(localized: "Commands"),
        commands: [
          command("new-chapter", String(localized: "New chapter"), systemImage: "plus", shortcut: KeyboardShortcut("n", modifiers: .command)),
          command(
            "finalize", String(localized: "Finalize into canon"), systemImage: "checkmark.circle", shortcut: KeyboardShortcut("f", modifiers: [.command, .shift]),
            keywords: [String(localized: "publish")]),
          command("duplicate", String(localized: "Duplicate chapter"), systemImage: "plus.square.on.square", shortcut: KeyboardShortcut("d", modifiers: .command)),
          command("drafts", String(localized: "Move to drafts"), systemImage: "tray"),
        ]),
      ShadowCommandSection(
        id: "pages", title: String(localized: "Pages"),
        commands: [
          command("glass-and-ash", String(localized: "Glass and Ash"), subtitle: String(localized: "Collection"), systemImage: "books.vertical"),
          command("story-bible", String(localized: "Story Bible"), systemImage: "doc.text"),
          command("secrets", String(localized: "Secrets"), systemImage: "lock"),
          command("settings", String(localized: "Settings"), systemImage: "gearshape", keywords: [String(localized: "preferences")]),
        ]),
    ]
  }
}
