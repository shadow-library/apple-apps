import ShadowDesignSystem
import SwiftUI

private typealias Item = ShadowNotification<Int>

private let labels = ShadowNotificationLabels(
  today: "Today", yesterday: "Yesterday", earlier: "Earlier", markRead: "Mark as read", markUnread: "Mark as unread", delete: "Delete", unread: "Unread"
)

struct NotificationListPage: View {
  @State private var items: [Item] = Self.sample
  @State private var longItems: [Item] = Self.longSample
  @State private var showsPopover = false

  private let now = Date.catalogNow

  private static let sample: [Item] = [
    Item(id: 1, title: "Chapter 43 is out", source: "The Ninth Archive", date: .catalogNow.catalogAgo(minutes: 2)),
    Item(id: 2, title: "Your streak is 12 days", source: "Memoir", date: .catalogNow.catalogAgo(hours: 1)),
    Item(id: 3, title: "New sign-in on iPad", source: "Identity", date: .catalogNow.catalogAgo(hours: 3), isRead: true),
    Item(id: 4, title: "Chapter 42 was updated", source: "The Glass Stair", date: .catalogNow.catalogAgo(hours: 20), isRead: true),
    Item(id: 5, title: "Weekly digest delivered", source: "Pulse", date: .catalogNow.catalogAgo(days: 5), isRead: true),
  ]

  private static let longSample: [Item] = [
    Item(
      id: 11, title: "Mira Vale replied to your note on the Archivist’s secret name",
      message: "“I think the reveal lands better if the lantern scene comes first, and Chapter 43 can then open on the stair.”",
      source: "The Ninth Archive", date: .catalogNow.catalogAgo(minutes: 14), icon: .avatar(name: "Mira Vale")),
    Item(
      id: 12, title: "Export finished", message: "Your EPUB is ready.", source: "Pulse", date: .catalogNow.catalogAgo(hours: 5), isRead: true, icon: .symbol("square.and.arrow.up")),
  ]

  var body: some View {
    List {
      StateListSection("Default", note: "Newest first, grouped by day. Unread rows lead with an accent dot and a semibold title; swipe right to toggle read, left to delete.") {}
      sections(for: $items)
      StateListSection("With icons and messages", note: "An avatar or symbol tile sits after the unread dot; messages take up to two lines.") {}
      sections(for: $longItems)
      StateListSection("Loading", note: "Skeleton rows hold the layout until the first response.") {
        ForEach(["skeleton-first", "skeleton-second"], id: \.self) { _ in NotificationSkeletonRow() }
      }
      StateListSection("Empty", note: "Say the fact, then the next step.") {
        ShadowContentUnavailable("You’re all caught up", systemImage: "bell", message: "New updates show up here.")
          .frame(maxWidth: .infinity, minHeight: 200)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(ShadowColor.surfaceCard)
      }
      CatalogListEnd()
    }
    .shadowListStyle()
    .toolbar {
      ToolbarItem {
        ShadowMarkAllReadButton("Mark all as read", unreadCount: (items + longItems).shadowUnreadCount()) {
          markAllRead(in: $items)
          markAllRead(in: $longItems)
        }
      }
      ToolbarItem {
        Button("Updates", systemImage: "bell") { showsPopover = true }
          .badge((items + longItems).shadowUnreadCount())
          .popover(isPresented: $showsPopover) {
            ShadowNotificationList(
              items, now: now, labels: labels, onOpen: { markRead($0, in: $items) }, onToggleRead: { toggle($0, in: $items) }, onDelete: { delete($0, in: $items) }
            ) {
              ShadowContentUnavailable("You’re all caught up", systemImage: "bell", message: "New updates show up here.")
            }
            .frame(minWidth: 320, minHeight: 400)
          }
      }
    }
    .catalogListPage(.notificationList, anchors: ["Default", "With icons and messages", "Loading", "Empty"])
    .catalogAutoPresent($showsPopover)
  }

  @ViewBuilder
  private func sections(for binding: Binding<[Item]>) -> some View {
    ShadowNotificationSections(
      binding.wrappedValue, now: now, labels: labels, onOpen: { markRead($0, in: binding) }, onToggleRead: { toggle($0, in: binding) }, onDelete: { delete($0, in: binding) })
  }

  private func markRead(_ id: Int, in items: Binding<[Item]>) {
    guard let index = items.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
    items.wrappedValue[index].isRead = true
  }

  private func toggle(_ id: Int, in items: Binding<[Item]>) {
    guard let index = items.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
    items.wrappedValue[index].isRead.toggle()
  }

  private func delete(_ id: Int, in items: Binding<[Item]>) {
    items.wrappedValue.removeAll { $0.id == id }
  }

  private func markAllRead(in items: Binding<[Item]>) {
    for index in items.wrappedValue.indices { items.wrappedValue[index].isRead = true }
  }
}

private struct NotificationSkeletonRow: View {
  var body: some View {
    HStack(spacing: Spacing.space3) {
      ShadowSkeletonCircle(diameter: 8)
      VStack(alignment: .leading, spacing: Spacing.space2) {
        ShadowSkeletonLine(.title, widthFraction: 0.5)
        ShadowSkeletonLine(widthFraction: 0.75)
      }
    }
    .padding(.horizontal, ShadowListMetrics().horizontalPadding)
    .padding(.vertical, ShadowListMetrics().verticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowSkeleton(true, label: "Loading")
    .listRowInsets(EdgeInsets())
    .listRowBackground(ShadowColor.surfaceCard)
  }
}
