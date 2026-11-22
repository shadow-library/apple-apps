import ShadowDesignSystem
import SwiftUI

/// The quiet sync indicator in the sidebar's toolbar: hidden while sync is off, otherwise an icon whose popover says how sync stands and, when it needs
/// attention, what is wrong and what it stops. It never blocks anything.
public struct SyncStatusIndicator: View {
  @Environment(SyncRuntimes.self) private var sync
  @State private var isPresented = false

  public init() {}

  public var body: some View {
    if let indicator = SyncIndicator(sync.status, deviceNames: sync.deviceNames, scope: sync.attentionScope, app: sync.identity) {
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
      .popover(isPresented: $isPresented) { SyncStatusDetail(indicator: indicator).environment(\.appIdentity, sync.identity) }
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
  @Environment(SyncRuntimes.self) private var sync
  @State private var offer: RecoveryPhraseOffer?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text(verbatim: indicator.headline).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: indicator.detail).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
      if let scope = indicator.scope { Text(verbatim: scope).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary) }
      if let consequence = indicator.consequence {
        Text(verbatim: consequence).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary)
      }
      if let code = indicator.code {
        Text(verbatim: code).shadowFont(.caption).foregroundStyle(ShadowColor.textTertiary).textSelection(.enabled)
      }
      if sync.status.needsKey { SyncKeysButton(start: .overview).buttonStyle(.shadowPlain) }
      if let offer, offer.vault != nil { RecoveryPhraseOfferCallout(offer: offer, open: nil) }
      SyncSettingsButton().buttonStyle(.shadowPlain)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(idealWidth: 300, maxWidth: 360, alignment: .leading)
    .padding(Spacing.space4)
    .presentationCompactAdaptation(.popover)
    .task {
      let offer = RecoveryPhraseOffer(sync: sync)
      await offer.refresh()
      self.offer = offer
    }
  }
}
