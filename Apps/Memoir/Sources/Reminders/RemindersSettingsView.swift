import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct RemindersSettingsView: View {
  let scheduler: ReminderScheduler
  @Environment(\.openURL) private var openURL

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        ShadowGroupedSection {
          Toggle(isOn: Binding(get: { scheduler.isOnThisDevice }, set: { scheduler.setOnThisDevice($0) })) {
            Text("Remind me on this device", tableName: "Reminders")
          }
          .padding(Spacing.space3)
        } footer: {
          VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(
              "Quests and subscriptions with a reminder turned on notify you on the devices where this is on. Each device keeps its own choice.",
              tableName: "Reminders")
            Text(
              "A quest you complete on another device stops reminding here once the change syncs; a reminder due before then may still arrive.",
              tableName: "Reminders")
            Text("Reminders are only for what you planned. Memoir never notifies you about a missed quest or about time away from the app.", tableName: "Reminders")
          }
        }
        if scheduler.isOnThisDevice { notes }
      }
      .padding(Spacing.space4)
      .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle(Text("Reminders", tableName: "Reminders"))
    .shadowScreen(.pushed)
    .task { await scheduler.refreshAuthorization() }
  }

  @ViewBuilder
  private var notes: some View {
    switch scheduler.authorization {
    case .denied:
      ShadowCallout(
        Text("Notifications are off for Memoir", tableName: "Reminders"),
        message: Text("Allow notifications in Settings to get reminders on this device.", tableName: "Reminders"), intent: .warning,
        systemImage: "bell.slash"
      ) {
        if let url = Self.notificationSettings {
          Button {
            openURL(url)
          } label: {
            Text("Open Settings", tableName: "Reminders")
          }
          .buttonStyle(.shadowBordered)
        }
      }
    case .notDetermined:
      ShadowCallout(
        Text("Memoir asks first", tableName: "Reminders"),
        message: Text("Memoir asks to send notifications once it has a reminder to schedule.", tableName: "Reminders"), intent: .neutral,
        systemImage: "bell")
    case .allowed:
      Text("\(scheduler.upcoming) reminders are set on this device for the coming week.", tableName: "Reminders")
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
    case nil:
      EmptyView()
    }
    if scheduler.questsPaused {
      ShadowCallout(
        Text("Quest reminders are paused", tableName: "Reminders"),
        message: Text(
          "Another device recorded something this version can’t read. Quest reminders resume once Memoir is updated; subscription reminders still arrive.",
          tableName: "Reminders"),
        intent: .warning, systemImage: "arrow.down.app")
    }
    if scheduler.omitted > 0 {
      ShadowCallout(
        Text("Some reminders are waiting", tableName: "Reminders"),
        message: Text(
          "\(scheduler.omitted) more reminders this week don’t fit yet. Memoir schedules them the next time it’s open after earlier ones have arrived.",
          tableName: "Reminders"),
        intent: .info, systemImage: "clock")
    }
  }

  private static var notificationSettings: URL? {
    #if os(macOS)
      URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? AppIdentity.memoir.id)")
    #else
      URL(string: UIApplication.openNotificationSettingsURLString)
    #endif
  }
}

#Preview {
  NavigationStack {
    RemindersSettingsView(
      scheduler: ReminderScheduler(
        notifications: InertReminderNotifications(), setting: ReminderDeviceSetting(defaults: UserDefaults(suiteName: "com.shadow.apps.memoir.previews") ?? .standard),
        restartOn: []))
  }
  .shadowTheme()
}
