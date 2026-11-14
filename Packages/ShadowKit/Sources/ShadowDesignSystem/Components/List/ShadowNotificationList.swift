import SwiftUI

nonisolated public enum ShadowNotificationLayout {
  public static let dotDiameter: CGFloat = 8

  public static func iconSlotWidth(density: ShadowDensity = .current) -> CGFloat {
    density == .touch ? ShadowAvatarSize.medium.diameter : ShadowAvatarSize.small.diameter
  }

  public static func leadingWidth(reservesIconSlot: Bool, density: ShadowDensity = .current) -> CGFloat {
    dotDiameter + (reservesIconSlot ? Spacing.space2 + iconSlotWidth(density: density) : 0)
  }
}

public struct ShadowNotificationLabels {
  public let today: LocalizedStringKey
  public let yesterday: LocalizedStringKey
  public let earlier: LocalizedStringKey
  public let markRead: LocalizedStringKey
  public let markUnread: LocalizedStringKey
  public let delete: LocalizedStringKey
  public let unread: LocalizedStringKey

  public init(
    today: LocalizedStringKey, yesterday: LocalizedStringKey, earlier: LocalizedStringKey, markRead: LocalizedStringKey, markUnread: LocalizedStringKey,
    delete: LocalizedStringKey, unread: LocalizedStringKey
  ) {
    self.today = today
    self.yesterday = yesterday
    self.earlier = earlier
    self.markRead = markRead
    self.markUnread = markUnread
    self.delete = delete
    self.unread = unread
  }

  func title(for bucket: ShadowDayBucket) -> LocalizedStringKey {
    switch bucket {
    case .today: today
    case .yesterday: yesterday
    case .earlier: earlier
    }
  }
}

public struct ShadowNotificationRow<ID: Hashable & Sendable>: View {
  private let notification: ShadowNotification<ID>
  private let now: Date
  private let unreadLabel: LocalizedStringKey
  private let reservesIconSlot: Bool

  @ScaledMetric(relativeTo: .body) private var dotSize = ShadowNotificationLayout.dotDiameter
  @ScaledMetric(relativeTo: .body) private var slotWidth = ShadowNotificationLayout.iconSlotWidth()

  public init(_ notification: ShadowNotification<ID>, now: Date = .now, unreadLabel: LocalizedStringKey, reservesIconSlot: Bool? = nil) {
    self.notification = notification
    self.now = now
    self.unreadLabel = unreadLabel
    self.reservesIconSlot = reservesIconSlot ?? (notification.icon != .none)
  }

  private var meta: Text {
    let time = ShadowRelativeTime.string(for: notification.date, now: now)
    guard let source = notification.source, !source.isEmpty else { return Text(verbatim: time) }
    return Text(verbatim: "\(source) · \(time)")
  }

  public var body: some View {
    let hasMessage = notification.message?.isEmpty == false
    ShadowListRow(
      title: Text(verbatim: notification.title),
      subtitle: hasMessage ? notification.message.map { Text(verbatim: $0) } : meta,
      caption: hasMessage ? meta : nil,
      isEmphasized: !notification.isRead,
      leading: {
        HStack(spacing: Spacing.space2) {
          Circle()
            .fill(notification.isRead ? Color.clear : ShadowColor.accent)
            .frame(width: dotSize, height: dotSize)
            .accessibilityHidden(true)
          if reservesIconSlot {
            icon.frame(width: slotWidth)
          }
        }
      }
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(notification.isRead ? Text(verbatim: "") : Text(unreadLabel))
  }

  @ViewBuilder
  private var icon: some View {
    switch notification.icon {
    case .none: EmptyView()
    case .symbol(let name, let tint): ShadowSymbolTile(systemImage: name, tint: tint)
    case .avatar(let name): ShadowAvatar(name: name, size: ShadowDensity.current == .touch ? .medium : .small)
    }
  }
}

public struct ShadowNotificationSections<ID: Hashable & Sendable>: View {
  private let notifications: [ShadowNotification<ID>]
  private let now: Date
  private let calendar: Calendar
  private let labels: ShadowNotificationLabels
  private let onOpen: (ID) -> Void
  private let onToggleRead: (ID) -> Void
  private let onDelete: (ID) -> Void

  public init(
    _ notifications: [ShadowNotification<ID>], now: Date = .now, calendar: Calendar = .current, labels: ShadowNotificationLabels, onOpen: @escaping (ID) -> Void,
    onToggleRead: @escaping (ID) -> Void, onDelete: @escaping (ID) -> Void
  ) {
    self.notifications = notifications
    self.now = now
    self.calendar = calendar
    self.labels = labels
    self.onOpen = onOpen
    self.onToggleRead = onToggleRead
    self.onDelete = onDelete
  }

  public var body: some View {
    let reservesIconSlot = notifications.contains { $0.icon != .none }
    ForEach(notifications.shadowGroupedByDay(now: now, calendar: calendar)) { group in
      Section {
        ForEach(group.notifications) { notification in
          Button {
            onOpen(notification.id)
          } label: {
            ShadowNotificationRow(notification, now: now, unreadLabel: labels.unread, reservesIconSlot: reservesIconSlot)
          }
          .buttonStyle(.plain)
          .shadowRowActions(leading: [toggleAction(notification)], trailing: [deleteAction(notification)])
        }
      } header: {
        ShadowSectionHeader(labels.title(for: group.bucket))
      }
    }
  }

  private func toggleAction(_ notification: ShadowNotification<ID>) -> ShadowRowAction {
    ShadowRowAction(
      id: "toggle-read",
      title: notification.isRead ? labels.markUnread : labels.markRead,
      systemImage: notification.isRead ? "envelope.badge" : "checkmark"
    ) { onToggleRead(notification.id) }
  }

  private func deleteAction(_ notification: ShadowNotification<ID>) -> ShadowRowAction {
    ShadowRowAction(id: "delete", title: labels.delete, systemImage: "trash", kind: .destructive) { onDelete(notification.id) }
  }
}

public struct ShadowNotificationList<ID: Hashable & Sendable, Empty: View>: View {
  private let notifications: [ShadowNotification<ID>]
  private let now: Date
  private let calendar: Calendar
  private let labels: ShadowNotificationLabels
  private let onOpen: (ID) -> Void
  private let onToggleRead: (ID) -> Void
  private let onDelete: (ID) -> Void
  private let empty: Empty

  public init(
    _ notifications: [ShadowNotification<ID>], now: Date = .now, calendar: Calendar = .current, labels: ShadowNotificationLabels, onOpen: @escaping (ID) -> Void,
    onToggleRead: @escaping (ID) -> Void, onDelete: @escaping (ID) -> Void, @ViewBuilder empty: () -> Empty
  ) {
    self.notifications = notifications
    self.now = now
    self.calendar = calendar
    self.labels = labels
    self.onOpen = onOpen
    self.onToggleRead = onToggleRead
    self.onDelete = onDelete
    self.empty = empty()
  }

  public var body: some View {
    List {
      ShadowNotificationSections(notifications, now: now, calendar: calendar, labels: labels, onOpen: onOpen, onToggleRead: onToggleRead, onDelete: onDelete)
    }
    .shadowListStyle()
    .overlay {
      if notifications.isEmpty { empty }
    }
  }
}

public struct ShadowMarkAllReadButton: View {
  private let title: LocalizedStringKey
  private let unreadCount: Int
  private let action: () -> Void

  public init(_ title: LocalizedStringKey, unreadCount: Int, action: @escaping () -> Void) {
    self.title = title
    self.unreadCount = unreadCount
    self.action = action
  }

  public var body: some View {
    Button(title, systemImage: "checkmark.circle", action: action)
      .disabled(unreadCount == 0)
  }
}
