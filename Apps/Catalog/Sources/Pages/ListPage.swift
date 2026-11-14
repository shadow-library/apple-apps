import ShadowDesignSystem
import SwiftUI

struct ListPage: View {
  @State private var selection: String? = "G&A"
  @State private var notificationsOn = true

  private var books: [CatalogBook] { Array(CatalogBook.shelf.prefix(3)) }

  var body: some View {
    List(selection: $selection) {
      StateListSection("Library", note: "Inset grouped on surface-card. Rows grow to two lines before truncating, and separators start at the text.") {
        ShadowListRow(title: Text(verbatim: "Continue reading"), subtitle: Text(verbatim: "The Ninth Archive · Chapter 42"), accessory: .chevron, isEmphasized: true) {
          ListCover(book: books[0])
        }
        ShadowListRow(title: Text(verbatim: "Glass and Ash"), subtitle: Text(verbatim: "64 chapters · 38% read"), accessory: .chevron) { ListCover(book: books[1]) }
        ShadowListRow(title: Text(verbatim: "Salt Kings"), subtitle: Text(verbatim: "Finished"), accessory: .chevron) { ListCover(book: books[2]) }
      }
      StateListSection("Settings", note: "Symbol tiles only in settings-style lists. Destructive rows go last in destructive-label.") {
        ShadowListRow("Notifications", value: notificationsOn ? "On" : "Off", accessory: .chevron) { ShadowSymbolTile(systemImage: "bell") }
        ShadowListRow("Appearance", value: "System", accessory: .chevron) { ShadowSymbolTile(systemImage: "moon") }
        ShadowListRow("Language", value: "English", accessory: .chevron) { ShadowSymbolTile(systemImage: "globe", tint: .neutral) }
        ShadowListRow("Sign out", role: .destructive)
      }
      StateListSection("Selected", note: "Touch uses accent-soft with accent-text. Mac uses selection-row with on-accent text while the window is active.") {
        ForEach(books) { book in
          ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), isSelected: selection == book.id) { ListCover(book: book) }
            .tag(book.id)
        }
      }
      StateListSection("Badges and values", note: "Trailing badges and values sit before the chevron; the value never pushes the title below two lines.") {
        ShadowListRow("Updates", value: "3 new", accessory: .chevron) { ShadowSymbolTile(systemImage: "bell.badge") }
        ShadowListRow("Messages", accessory: .chevron, leading: { ShadowSymbolTile(systemImage: "bubble.left", tint: .chart(3)) }, trailing: { ShadowBadge(count: 128) })
        ShadowListRow(
          "Review queue", accessory: .chevron, leading: { ShadowSymbolTile(systemImage: "checkmark.seal", tint: .warm) }, trailing: { ShadowBadge("Beta", intent: .info) })
      }
      StateListSection("Disabled", note: "Disabled rows fall to 45% opacity and ignore input.") {
        ShadowListRow("Export to EPUB", subtitle: "Finalize the chapter first", accessory: .chevron) { ShadowSymbolTile(systemImage: "square.and.arrow.up") }
          .disabled(true)
        ShadowListRow("Share link", value: "Off", accessory: .chevron) { ShadowSymbolTile(systemImage: "link") }
          .disabled(true)
      }
      StateListSection("Long text", note: "Two lines for the title and two for the subtitle, then a tail ellipsis. The leading view never shrinks.") {
        ShadowListRow(
          title: Text(verbatim: "The Glass Stair and the Archive of Forgotten Lanterns, Volume Two"),
          subtitle: Text(verbatim: "Chapter 42 of 60 · Last edited by Mira Vale with the Archivist’s notes folded in, still awaiting review"),
          value: Text(verbatim: "Draft"),
          accessory: .chevron
        ) { ListCover(book: books[1]) }
        ShadowListRow("Allow readers to unlock wiki entries once they reach the chapter that reveals them", value: "On", accessory: .chevron)
      }
      StateListSection("Loading", note: "The real rows under `.shadowSkeleton`; bars take the real text sizes.") {
        ForEach(Array(books.enumerated()), id: \.offset) { _, book in
          ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), accessory: .chevron) { ListCover(book: book).shadowSkeletonShape() }
            .shadowSkeleton(true, label: "Loading")
        }
      }
      StateListSection("Empty", note: "ShadowContentUnavailable names the fact and the next step.") {
        ShadowContentUnavailable("No quests yet", message: "Create your first quest and it will show up here.")
          .frame(maxWidth: .infinity, minHeight: 200)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(ShadowColor.surfaceCard)
      }
    }
    .shadowListStyle()
    .catalogListPage(.list, anchors: ["Library", "Settings", "Selected", "Badges and values", "Disabled", "Long text", "Loading", "Empty"])
  }
}
