import Foundation
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// Every zone this device knows, searchable, as `timeZoneOptions` lists them (`lib/format/date-time.ts:67-74`), plus the ones already chosen.
struct TimeZoneList: View {
  let selected: String?
  let deviceZone: String
  let choose: (String) async -> Bool
  @State private var query = ""
  @State private var choosing = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let now = Date()
    List(Self.matching(query, including: [selected, deviceZone].compactMap(\.self)), id: \.self) { identifier in
      Button {
        guard !choosing else { return }
        choosing = true
        Task {
          if await choose(identifier) { dismiss() }
          choosing = false
        }
      } label: {
        HStack(spacing: Spacing.space3) {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: SettingsCopy.zone(identifier)).foregroundStyle(ShadowColor.textPrimary)
            if let offset = SettingsCopy.offset(of: identifier, at: now) {
              Text(verbatim: offset).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
            }
          }
          Spacer(minLength: Spacing.space3)
          if identifier == selected {
            Image(systemName: "checkmark").foregroundStyle(ShadowColor.accent).accessibilityHidden(true)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(identifier == selected ? .isSelected : [])
    }
    .searchable(text: $query, prompt: Text("Search time zones", tableName: "Settings"))
    .navigationTitle(Text("Time zone", tableName: "Settings"))
    .shadowScreen(.pushed)
  }

  nonisolated static func matching(_ query: String, including extra: [String]) -> [String] {
    let zones = Set(TimeZone.knownTimeZoneIdentifiers).union(extra).sorted()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return zones }
    return zones.filter { SettingsCopy.zone($0).localizedStandardContains(trimmed) }
  }
}

/// Settings' time zone: a change is staged for the next day when a zone is in force (`account.service.ts:137-139`).
struct SettingsTimeZoneView: View {
  @State private var model: SettingsModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: SettingsModel(context: context))
  }

  var body: some View {
    TimeZoneList(selected: model.snapshot.state.value?.chosenZone, deviceZone: model.deviceZone) { identifier in await model.setTimeZone(identifier) }
      .safeAreaInset(edge: .bottom) {
        if let error = model.failure(for: .timeZone) {
          ShadowCallout(Text("The time zone wasn’t changed", tableName: "Settings"), message: error.text, intent: .danger).padding(Spacing.space4)
        }
      }
      .task { await model.run() }
  }
}

#Preview {
  NavigationStack {
    TimeZoneList(selected: "Europe/Berlin", deviceZone: "Europe/Berlin") { _ in true }
  }
  .shadowTheme()
}
