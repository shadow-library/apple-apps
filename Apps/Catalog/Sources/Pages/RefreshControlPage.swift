import ShadowDesignSystem
import SwiftUI

struct RefreshControlPage: View {
  @State private var updates = UpdateItem.sample
  @State private var refreshCount = 0

  var body: some View {
    List {
      StateListSection(
        "Updates",
        note: "Pull down on iPhone and iPad; the system spinner appears above the first row. On Mac use the Refresh toolbar button or ⌘R. Refreshing prepends a new chapter."
      ) {
        ForEach(updates) { update in
          ShadowListRow(
            title: Text(verbatim: update.title),
            subtitle: Text(verbatim: update.detail),
            accessory: .chevron,
            isEmphasized: update.isUnread,
            leading: { Circle().fill(update.isUnread ? ShadowColor.accent : Color.clear).frame(width: 8, height: 8) }
          )
        }
      }
      #if !os(macOS)
        Section {
          ForEach(updates.prefix(2)) { update in
            ShadowListRow(
              title: Text(verbatim: update.title),
              subtitle: Text(verbatim: update.detail),
              accessory: .chevron,
              isEmphasized: update.isUnread,
              leading: { Circle().fill(update.isUnread ? ShadowColor.accent : Color.clear).frame(width: 8, height: 8) }
            )
          }
        } header: {
          VStack(spacing: Spacing.space4) {
            ShadowSectionHeader("Refreshing")
              .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView()
              .accessibilityLabel("Refreshing")
          }
        } footer: {
          Text("A static rendering of a pull in progress: the system spinner sits above the first row until the reload finishes.")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
        .id("Refreshing")
      #endif
      StateListSection("Loading", note: "Before the first response arrives, skeleton rows keep the layout; pull to refresh is for later reloads.") {
        ForEach(Array(updates.enumerated()), id: \.offset) { _, update in
          ShadowListRow(title: Text(verbatim: update.title), subtitle: Text(verbatim: update.detail), accessory: .chevron)
            .shadowSkeleton(true, label: "Loading")
        }
      }
      StateListSection("Empty", note: "An empty list is still refreshable, so the empty state names the way to refresh.") {
        ShadowContentUnavailable("You’re all caught up", systemImage: "tray", message: Self.emptyMessage)
          .frame(maxWidth: .infinity, minHeight: 200)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(ShadowColor.surfaceCard)
      }
    }
    .shadowListStyle()
    .shadowRefreshable("Refresh") {
      try? await Task.sleep(for: .seconds(1))
      refreshCount += 1
      updates.insert(UpdateItem(id: 43 + refreshCount, title: "Chapter \(43 + refreshCount) · New arrival", detail: "The Ninth Archive · just now", isUnread: true), at: 0)
    }
    .catalogListPage(.refreshControl, anchors: Self.anchors)
  }

  private static var emptyMessage: LocalizedStringKey {
    #if os(macOS)
      "New chapters show up here. Refresh with ⌘R to check again."
    #else
      "New chapters show up here. Pull down to check again."
    #endif
  }

  private static var anchors: [String] {
    #if os(macOS)
      ["Updates", "Loading", "Empty"]
    #else
      ["Updates", "Refreshing", "Loading", "Empty"]
    #endif
  }
}
