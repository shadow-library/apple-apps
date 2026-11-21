import ShadowDesignSystem
import SwiftUI

/// The quiet sync indicator in the sidebar's toolbar: hidden while sync is off, otherwise an icon whose popover says how sync stands and, when it needs
/// attention, what is wrong and what it stops. It never blocks anything.
struct SyncStatusIndicator: View {
  @Environment(SyncRuntimes.self) private var sync
  @State private var isPresented = false

  var body: some View {
    if let indicator = SyncIndicator(sync.status, deviceNames: sync.deviceNames) {
      Button {
        isPresented = true
      } label: {
        Label {
          Text(verbatim: indicator.accessibilityLabel)
        } icon: {
          Image(systemName: Self.symbol(indicator.tone))
            .foregroundStyle(indicator.tone == .attention ? ShadowColor.warningText : ShadowColor.textSecondary)
        }
      }
      .help(Text(verbatim: indicator.headline))
      .accessibilityLabel(Text(verbatim: indicator.accessibilityLabel))
      .popover(isPresented: $isPresented) { SyncStatusDetail(indicator: indicator) }
    }
  }

  private static func symbol(_ tone: SyncIndicator.Tone) -> String {
    switch tone {
    case .upToDate: "checkmark.circle"
    case .syncing: "arrow.triangle.2.circlepath"
    case .attention: "exclamationmark.triangle.fill"
    }
  }
}

private struct SyncStatusDetail: View {
  let indicator: SyncIndicator

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text(verbatim: indicator.headline).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: indicator.detail).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
      if let consequence = indicator.consequence {
        Text(verbatim: consequence).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
      }
      if let code = indicator.code {
        Text(verbatim: code).shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary).textSelection(.enabled)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(idealWidth: 300, maxWidth: 360, alignment: .leading)
    .padding(Spacing.space4)
    .presentationCompactAdaptation(.popover)
  }
}
