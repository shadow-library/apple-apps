import ShadowDesignSystem
import SwiftUI

private struct Update: Identifiable, Hashable {
  let id: Int
  let title: String
  let detail: String
  var isUnread: Bool
  var isFlagged = false
}

struct SwipeActionsPage: View {
  @State private var updates = [
    Update(id: 1, title: "Chapter 43 is out", detail: "The Ninth Archive · 2 min", isUnread: true),
    Update(id: 2, title: "Your streak is 12 days", detail: "Memoir · 1 h", isUnread: true),
    Update(id: 3, title: "New sign-in on iPad", detail: "Identity · 3 h", isUnread: false),
    Update(id: 4, title: "Weekly digest delivered", detail: "Pulse · Mon", isUnread: false),
  ]

  var body: some View {
    List {
      StateListSection(
        "Default", note: "Swipe right to mark read; swipe left for Flag and Delete. Destructive is outermost, and a full swipe runs it. Every action is also in the context menu."
      ) {
        ForEach(updates) { update in
          row(update)
            .shadowRowActions(
              leading: [
                ShadowRowAction(
                  id: "read", title: update.isUnread ? "Read" : "Unread", systemImage: update.isUnread ? "checkmark" : "envelope.badge",
                  shortcut: KeyboardShortcut("u", modifiers: [.command, .shift])
                ) {
                  toggle(update.id)
                }
              ],
              trailing: [
                ShadowRowAction(id: "flag", title: "Flag", systemImage: "flag", kind: .warning, shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { flag(update.id) },
                ShadowRowAction(id: "delete", title: "Delete", systemImage: "trash", kind: .destructive, shortcut: KeyboardShortcut(.delete, modifiers: [])) { delete(update.id) },
              ]
            )
        }
      }
      StateListSection(
        "Revealed",
        note:
          "A static rendering of the system swipe: the row slides aside to reveal the leading reversible action in accent, trailing Flag in warning-solid-strong and Delete in danger-solid, each labelled with a word."
      ) {
        RevealedRow(update: Update(id: 10, title: "Your streak is 12 days", detail: "Memoir · 1 h", isUnread: true), edge: .leading)
        RevealedRow(update: Update(id: 11, title: "Chapter 43 is out", detail: "The Ninth Archive · 2 min", isUnread: false), edge: .trailing)
      }
      StateListSection("Disabled", note: "Disabled rows offer no swipe and no context menu.") {
        row(Update(id: 30, title: "Archived: Weekly digest", detail: "Pulse · Last month", isUnread: false))
          .disabled(true)
      }
      StateListSection("Long text", note: "Two lines of title and subtitle; the action labels stay one word.") {
        row(
          Update(
            id: 20, title: "Chapter 43 of The Ninth Archive is out, and the Archivist has left you a note about the lanterns",
            detail: "The Ninth Archive · Written by Mira Vale · 2 min", isUnread: true)
        )
        .shadowRowActions(
          leading: [ShadowRowAction(id: "read", title: "Read", systemImage: "checkmark") {}],
          trailing: [ShadowRowAction(id: "delete", title: "Delete", systemImage: "trash", kind: .destructive) {}]
        )
      }
      #if os(macOS)
        StateListSection(
          "Context menu",
          note:
            "A static illustration of the context menu. Right-click any row above for the real one: mice cannot swipe, so each action is mirrored with its shortcut and Delete sits last in destructive-label."
        ) {
          ContextMenuPreview()
        }
      #else
        StateListSection("Context menu", note: "On Mac and iPad with a keyboard the actions carry shortcuts, because mice and trackpads cannot always swipe.") {
          ShadowListRow(
            title: Text(verbatim: "Touch and hold any row above"), subtitle: Text(verbatim: "The same actions open as a menu, Delete last."),
            leading: { UnreadDot(isUnread: false) }
          )
        }
      #endif
      CatalogListEnd()
    }
    .shadowListStyle()
    .catalogListPage(.swipeActions, anchors: ["Default", "Revealed", "Disabled", "Long text", "Context menu"])
  }

  private func row(_ update: Update) -> some View {
    ShadowListRow(
      title: Text(verbatim: update.title),
      subtitle: Text(verbatim: update.detail),
      isEmphasized: update.isUnread,
      leading: { UnreadDot(isUnread: update.isUnread) },
      trailing: {
        if update.isFlagged { Image(systemName: "flag.fill").foregroundStyle(ShadowColor.warningSolid) }
      }
    )
  }

  private func toggle(_ id: Int) {
    guard let index = updates.firstIndex(where: { $0.id == id }) else { return }
    updates[index].isUnread.toggle()
  }

  private func flag(_ id: Int) {
    guard let index = updates.firstIndex(where: { $0.id == id }) else { return }
    updates[index].isFlagged.toggle()
  }

  private func delete(_ id: Int) {
    updates.removeAll { $0.id == id }
  }
}

private struct UnreadDot: View {
  let isUnread: Bool

  var body: some View {
    Circle()
      .fill(isUnread ? ShadowColor.accent : Color.clear)
      .frame(width: 8, height: 8)
  }
}

private struct RevealedRow: View {
  enum Edge { case leading, trailing }

  let update: Update
  let edge: Edge

  private let tileWidth: CGFloat = 72
  private let insets = ShadowListMetrics().rowInsets
  private var revealedWidth: CGFloat { edge == .leading ? tileWidth : tileWidth * 2 }
  private var sectionRadius: CGFloat { ShadowDensity.current == .touch ? Radius.panel : 0 }

  private var shape: UnevenRoundedRectangle {
    edge == .leading
      ? UnevenRoundedRectangle(topLeadingRadius: sectionRadius, topTrailingRadius: sectionRadius, style: .continuous)
      : UnevenRoundedRectangle(bottomLeadingRadius: sectionRadius, bottomTrailingRadius: sectionRadius, style: .continuous)
  }

  var body: some View {
    let separatorShift = edge == .leading ? revealedWidth : 0
    ShadowListRow(
      title: Text(verbatim: update.title),
      subtitle: Text(verbatim: update.detail),
      isEmphasized: update.isUnread,
      leading: { UnreadDot(isUnread: update.isUnread) }
    )
    .offset(x: edge == .leading ? revealedWidth : -revealedWidth)
    .background { background.padding(cellOutset) }
    .mask { shape.padding(cellOutset) }
    .accessibilityElement(children: .combine)
    .alignmentGuide(.listRowSeparatorLeading) { $0[.listRowSeparatorLeading] + separatorShift }
  }

  private var cellOutset: EdgeInsets {
    EdgeInsets(top: -insets.top, leading: -insets.leading, bottom: -insets.bottom, trailing: -insets.trailing)
  }

  private var background: some View {
    HStack(spacing: 0) {
      if edge == .leading { tile("Read", "checkmark", ShadowColor.accent) }
      ShadowColor.surfaceCard
      if edge == .trailing {
        tile("Flag", "flag", ShadowRowActionKind.warning.token.color)
        tile("Delete", "trash", ShadowColor.dangerSolid)
      }
    }
  }

  private func tile(_ title: LocalizedStringKey, _ systemImage: String, _ fill: Color) -> some View {
    VStack(spacing: Spacing.space1) {
      Image(systemName: systemImage).font(.body)
      Text(title).shadowFont(.footnote)
    }
    .foregroundStyle(ShadowColor.onAccent)
    .frame(width: tileWidth)
    .frame(maxHeight: .infinity)
    .background(fill)
  }
}

#if os(macOS)
  private struct ContextMenuPreview: View {
    var body: some View {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        item("Mark as read", "checkmark", "⇧⌘U", ShadowColor.textPrimary)
        item("Flag", "flag", "⇧⌘L", ShadowColor.textPrimary)
        Divider()
        item("Delete", "trash", "⌫", ShadowColor.destructiveLabel)
      }
      .padding(Spacing.space2)
      .frame(width: 240)
      .background(ShadowColor.surfaceRaised, in: .rect(cornerRadius: Radius.lg, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(ShadowColor.borderDefault) }
      .listRowBackground(Color.clear)
      .accessibilityHidden(true)
    }

    private func item(_ title: LocalizedStringKey, _ systemImage: String, _ shortcut: String, _ color: Color) -> some View {
      HStack {
        Label(title, systemImage: systemImage)
        Spacer()
        Text(verbatim: shortcut).foregroundStyle(ShadowColor.textTertiary)
      }
      .shadowFont(.body)
      .foregroundStyle(color)
      .padding(.horizontal, Spacing.space2)
      .frame(minHeight: ShadowMetrics.rowHeight)
    }
  }
#endif
