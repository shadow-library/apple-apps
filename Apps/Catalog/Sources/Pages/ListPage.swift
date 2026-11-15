import ShadowDesignSystem
import SwiftUI

struct ListPage: View {
  @State private var selection: String? = "G&A"
  @State private var notificationsOn = true

  private var books: [CatalogBook] { Array(CatalogBook.shelf.prefix(3)) }

  var body: some View {
    ComponentPage(component: .list) {
      StateSection(
        "Library",
        note:
          "ShadowGroupedSection cards on surface-card, so static rows can sit in columns. A native grouped List with .shadowListStyle() keeps the system grey grouped style on Mac (see Notification list and Swipe actions). Rows grow to two lines before truncating, and separators start at the text."
      ) {
        ShadowGroupedSection {
          ShadowListRow(
            title: Text(verbatim: "Continue reading"), subtitle: Text(verbatim: "The Ninth Archive · Chapter 42"), accessory: .chevron, isEmphasized: true
          ) { ListCover(book: books[0]) }
          ShadowListRow(title: Text(verbatim: "Glass and Ash"), subtitle: Text(verbatim: "64 chapters · 38% read"), accessory: .chevron) { ListCover(book: books[1]) }
          ShadowListRow(title: Text(verbatim: "Salt Kings"), subtitle: Text(verbatim: "Finished"), accessory: .chevron) { ListCover(book: books[2]) }
        }
      }
      StateSection("Settings", note: "Symbol tiles only in settings-style lists. Destructive rows go last in destructive-label.") {
        ShadowGroupedSection {
          ShadowListRow("Notifications", value: notificationsOn ? "On" : "Off", accessory: .chevron) { ShadowSymbolTile(systemImage: "bell") }
          ShadowListRow("Appearance", value: "System", accessory: .chevron) { ShadowSymbolTile(systemImage: "moon") }
          ShadowListRow("Language", value: "English", accessory: .chevron) { ShadowSymbolTile(systemImage: "globe", tint: .neutral) }
          ShadowListRow("Sign out", role: .destructive)
        }
      }
      StateSection(
        "Selected",
        note:
          "A native List with selection. Touch uses accent-soft with accent-text. Mac keeps the native band: accent with on-accent labels while the list is focused, grey otherwise."
      ) {
        SelectableListBlock(selection: $selection) {
          ForEach(books) { book in
            ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), isSelected: selection == book.id) { ListCover(book: book) }
              .tag(book.id)
          }
        }
        .catalogSnapshotFocus()
      }
      StateSection(
        "Symbol tiles", note: "Soft tiles for settings rows; a filled tile marks the one row that leads somewhere important. Large tiles head a sheet or an empty state."
      ) {
        ShadowGroupedSection {
          ShadowListRow("Account and security", value: "Soft", accessory: .chevron) { ShadowSymbolTile(systemImage: "shield") }
          ShadowListRow("Two-step verification", value: "Filled", accessory: .chevron) { ShadowSymbolTile(systemImage: "lock.shield", style: .filled) }
          ShadowListRow("Confirm it’s you", subtitle: "Large, filled", leading: { ShadowSymbolTile(systemImage: "shield", style: .filled, size: .large) })
          ShadowListRow("Recovery codes", subtitle: "Large, soft", leading: { ShadowSymbolTile(systemImage: "key", size: .large) })
        }
      }
      StateSection("Badges and values", note: "Trailing badges and values sit before the chevron; the value never pushes the title below two lines.") {
        ShadowGroupedSection {
          ShadowListRow("Updates", value: "3 new", accessory: .chevron) { ShadowSymbolTile(systemImage: "bell.badge") }
          ShadowListRow(
            "Messages", accessory: .chevron, leading: { ShadowSymbolTile(systemImage: "bubble.left", tint: .chart(3)) }, trailing: { ShadowBadge(count: 128) })
          ShadowListRow(
            "Review queue", accessory: .chevron, leading: { ShadowSymbolTile(systemImage: "checkmark.seal", tint: .warm) },
            trailing: { ShadowBadge("Beta", intent: .info) })
        }
      }
      StateSection("Disabled", note: "Disabled rows fall to 45% opacity and ignore input.") {
        ShadowGroupedSection {
          ShadowListRow("Export to EPUB", subtitle: "Finalize the chapter first", accessory: .chevron) { ShadowSymbolTile(systemImage: "square.and.arrow.up") }
            .disabled(true)
          ShadowListRow("Share link", value: "Off", accessory: .chevron) { ShadowSymbolTile(systemImage: "link") }
            .disabled(true)
        }
      }
      StateSection("Long text", note: "Two lines for the title and two for the subtitle, then a tail ellipsis. The leading view never shrinks.") {
        ShadowGroupedSection {
          ShadowListRow(
            title: Text(verbatim: "The Glass Stair and the Archive of Forgotten Lanterns, Volume Two"),
            subtitle: Text(verbatim: "Chapter 42 of 60 · Last edited by Mira Vale with the Archivist’s notes folded in, still awaiting review"),
            value: Text(verbatim: "Draft"),
            accessory: .chevron
          ) { ListCover(book: books[1]) }
          ShadowListRow("Allow readers to unlock wiki entries once they reach the chapter that reveals them", value: "On", accessory: .chevron)
        }
      }
      StateSection("Loading", note: "The real rows under `.shadowSkeleton`; bars take the real text sizes.") {
        ShadowGroupedSection {
          ForEach(Array(books.enumerated()), id: \.offset) { _, book in
            ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), accessory: .chevron) {
              ListCover(book: book).shadowSkeletonShape()
            }
            .shadowSkeleton(true, label: "Loading")
          }
        }
      }
      StateSection("Empty", note: "ShadowContentUnavailable names the fact and the next step.") {
        ShadowGroupedSection {
          ShadowContentUnavailable("No quests yet", message: "Create your first quest and it will show up here.")
            .frame(maxWidth: .infinity, minHeight: 200)
        }
      }
    }
  }
}
