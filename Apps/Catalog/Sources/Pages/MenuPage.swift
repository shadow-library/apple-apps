import ShadowDesignSystem
import SwiftUI

struct MenuPage: View {
  @State private var sort = ChapterSort.newest
  @State private var showsWordCount = true
  @State private var showsSecrets = false

  var body: some View {
    ComponentPage(component: .menu) {
      StateSection(
        "Open menu",
        note:
          "Native menus are glass and open in their own window, which screenshots can’t capture. This panel mirrors one: symbols lead, a titled section holds the choice, the destructive action comes last."
      ) {
        StaticIllustration {
          PresentationBackdrop(height: ShadowDensity.current == .touch ? 470 : 300, alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: Spacing.space2) {
              moreButton
              StaticMenuPanel(items: ShadowDensity.current == .touch ? Self.touchItems : Self.macItems)
            }
          }
        }
      }
      StateSection("Pull-down menu", note: "Tap the glass button for the real menu: sections, a sort picker with a checkmark, and Remove download last.") {
        PresentationBackdrop(height: 160, alignment: .topTrailing) {
          moreButton
        }
      }
      StateSection("Context menu", note: "Long-press a chapter on touch or secondary-click it on Mac. Mac lists keyboard shortcuts on the right.") {
        ShadowGroupedSection {
          ForEach(DemoChapter.recent.suffix(3)) { chapter in
            ShadowListRow(title: Text(verbatim: chapter.title), subtitle: Text(verbatim: chapter.heading), value: Text(verbatim: chapter.status.rawValue))
              .contentShape(.rect)
              .contextMenu { chapterActions }
          }
        }
      }
      StateSection("Submenu, toggle and picker", note: "Menus can nest one level, hold toggles and inline pickers.") {
        Menu {
          Toggle("Show word count", systemImage: "number", isOn: $showsWordCount)
          Toggle("Show secrets", systemImage: "lock", isOn: $showsSecrets)
          Picker("Sort by", selection: $sort) {
            ForEach(ChapterSort.allCases) { sort in Text(sort.title).tag(sort) }
          }
          .pickerStyle(.inline)
          Menu("Move to", systemImage: "folder") {
            ForEach(CatalogBook.shelf.prefix(4)) { book in Button(book.title) {} }
          }
        } label: {
          Label("View options", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.shadowBordered)
      }
      StateSection("Primary action", note: "A click runs the main action; the arrow or a long press shows the alternatives.") {
        Menu {
          Button("Export as EPUB", systemImage: "book.closed") {}
          Button("Export as PDF", systemImage: "doc.richtext") {}
          Button("Export as Markdown", systemImage: "doc.plaintext") {}
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        } primaryAction: {
        }
        .menuStyle(.button)
        .buttonStyle(.shadowBordered)
        .fixedSize()
      }
      StateSection("Disabled", note: "A menu with nothing to act on stays visible but dimmed.") {
        Menu("Collaborators") {
          Button("Invite…") {}
        }
        .buttonStyle(.shadowBordered)
        .fixedSize()
        .disabled(true)
      }
    }
  }

  private var moreButton: some View {
    Menu {
      Section {
        Button("Add to library", systemImage: "bookmark") {}
        Button("Share chapter", systemImage: "square.and.arrow.up") {}
        Button("Copy link", systemImage: "doc.on.doc") {}
      }
      Picker("Sort by", selection: $sort) {
        ForEach(ChapterSort.allCases) { sort in Text(sort.title).tag(sort) }
      }
      .pickerStyle(.inline)
      Section {
        Button("Remove download", systemImage: "trash", role: .destructive) {}
      }
    } label: {
      GlassCircleLabel {
        Label("More", systemImage: "ellipsis").labelStyle(.iconOnly)
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  @ViewBuilder
  private var chapterActions: some View {
    Section {
      Button("New chapter", systemImage: "plus") {}
        .keyboardShortcut("n", modifiers: .command)
      Button("Duplicate", systemImage: "plus.square.on.square") {}
        .keyboardShortcut("d", modifiers: .command)
      Button("Rename…", systemImage: "pencil") {}
        .keyboardShortcut(.return, modifiers: [])
    }
    Section {
      Button("Finalize into canon", systemImage: "checkmark.circle") {}
        .keyboardShortcut("f", modifiers: [.command, .shift])
      Button("Unlock secret", systemImage: "lock") {}
        .disabled(true)
    }
    Section {
      Button("Move to Trash", systemImage: "trash", role: .destructive) {}
        .keyboardShortcut(.delete, modifiers: .command)
    }
  }

  private static let touchItems: [StaticMenuItem] = [
    .action("Add to library", systemImage: "bookmark"),
    .action("Share chapter", systemImage: "square.and.arrow.up"),
    .action("Copy link", systemImage: "doc.on.doc"),
    .separator("share"),
    .sectionTitle("Sort by"),
    .action("Newest first", isChecked: true),
    .action("Oldest first"),
    .separator("sort"),
    .action("Remove download", systemImage: "trash", isDestructive: true),
  ]

  private static let macItems: [StaticMenuItem] = [
    .action("New chapter", systemImage: "plus", shortcut: KeyboardShortcut("n", modifiers: .command)),
    .action("Duplicate", systemImage: "plus.square.on.square", shortcut: KeyboardShortcut("d", modifiers: .command), isHighlighted: true),
    .action("Rename…", systemImage: "pencil", shortcut: KeyboardShortcut(.return, modifiers: [])),
    .separator("edit"),
    .action("Finalize into canon", systemImage: "checkmark.circle", shortcut: KeyboardShortcut("f", modifiers: [.command, .shift])),
    .action("Unlock secret", systemImage: "lock", isDisabled: true),
    .separator("canon"),
    .action("Move to Trash", systemImage: "trash", shortcut: KeyboardShortcut(.delete, modifiers: .command), isDestructive: true),
  ]
}

enum ChapterSort: String, CaseIterable, Identifiable {
  case newest
  case oldest

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .newest: "Newest first"
    case .oldest: "Oldest first"
    }
  }
}
