import ShadowDesignSystem
import ShadowSync
import ShadowSyncRuntime
import SwiftUI

public struct SyncSettingsView: View {
  @State private var model: SyncSettingsModel
  @State private var offer: RecoveryPhraseOffer
  @State private var keysRouteHere: SyncKeysStart?
  private let keysRoute: Binding<SyncKeysStart?>?
  @Environment(\.syncSettingsSection) private var appSection

  /// `keysRoute` lets another screen open Keys and Devices, as the Mac's sync indicator does through the Settings tabs.
  public init(sync: SyncRuntimes, keysRoute: Binding<SyncKeysStart?>? = nil) {
    _model = State(initialValue: SyncSettingsModel(sync: sync))
    _offer = State(initialValue: RecoveryPhraseOffer(sync: sync))
    self.keysRoute = keysRoute
  }

  private var route: Binding<SyncKeysStart?> { keysRoute ?? $keysRouteHere }

  private var isShowingKeys: Binding<Bool> {
    Binding(get: { route.wrappedValue != nil }, set: { if !$0 { route.wrappedValue = nil } })
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if model.isKeychainRefused { TeamlessCallout() }
        if case .attached(_, .vault(.awaitingKey)?) = model.overview, model.connect == nil { SyncKeysWaitingCallout { route.wrappedValue = .overview } }
        if offer.vault != nil, model.connect == nil { RecoveryPhraseOfferCallout(offer: offer) { route.wrappedValue = .phraseSetup } }
        SyncLocationSection(model: model)
        if let appSection, model.connect == nil { appSection.content() }
        if case .attached(_, .vaultMoved(let notice)?) = model.overview, model.connect == nil { MoveNoticeSection(model: model, notice: notice) }
        if let connect = model.connect { SyncConnectView(model: connect) { Task { await model.closeConnect() } } }
        keysSection
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .background(ShadowColor.surfaceApp)
    .task(id: model.sync.runtime.map(ObjectIdentifier.init)) { await model.refresh() }
    .task(id: model.sync.runtime.map(ObjectIdentifier.init)) { await offer.refresh() }
    .onChange(of: model.sync.status) {
      Task { await model.refresh() }
      Task { await offer.refresh() }
    }
    .navigationDestination(isPresented: isShowingKeys) { SyncKeysView(sync: model.sync, start: route.wrappedValue ?? .overview) }
    .onDisappear { if !isShowingKeys.wrappedValue { model.leave() } }
    .appIdentity(model.sync.identity)
  }

  private var keysSection: some View {
    ShadowGroupedSection {
      Button {
        route.wrappedValue = .overview
      } label: {
        Label {
          Text("Keys and Devices", tableName: "SyncSettings", bundle: .module)
        } icon: {
          Image(systemName: "key")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(Spacing.space3)
    } header: {
      Text("Keys", tableName: "SyncSettings", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "Your \(model.sync.identity.vaultNoun) is encrypted with keys that stay on your devices. The recovery phrase and your other devices are managed here.",
        tableName: "SyncSettings", bundle: .module)
    }
  }
}

private struct TeamlessCallout: View {
  @Environment(\.appIdentity) private var app
  var body: some View {
    ShadowCallout(
      Text(verbatim: SyncSettingsErrors(app: app).teamlessHeadline),
      message: Text(
        "Sync keeps your \(app.vaultNoun)'s keys in the keychain, and the system refuses the keychain to a build signed without a development team. Use a build signed with a team to sync on this device.",
        tableName: "SyncSettings", bundle: .module), intent: .danger, systemImage: "lock.trianglebadge.exclamationmark"
    ) { EmptyView() }
  }
}

private struct SyncLocationSection: View {
  @Environment(\.appIdentity) private var app
  let model: SyncSettingsModel

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        if let notice = model.notice { NoticeCallout(notice: notice) }
        content
        if let work = model.work { WorkingRow(text: text(for: work)) }
        if let confirmation = model.confirmation { ConfirmationCallout(model: model, confirmation: confirmation) }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Sync", tableName: "SyncSettings", bundle: .module).shadowFont(.headline)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.overview {
    case .loading:
      ProgressView().frame(maxWidth: .infinity)
    case .unavailable:
      Text("Sync settings are available once your \(app.vaultNoun) is open.", tableName: "SyncSettings", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
    case .unreadable(let error):
      error.text.foregroundStyle(ShadowColor.textSecondary)
    case .off(let reason):
      Text(verbatim: SyncLocationText(app: app).offReason(reason)).foregroundStyle(ShadowColor.textSecondary)
      if reason != .newerFormat, model.connect == nil {
        HStack {
          Spacer(minLength: Spacing.space3)
          Button {
            model.startConnect()
          } label: {
            Text("Turn On Sync", tableName: "SyncSettings", bundle: .module)
          }
          .buttonStyle(.shadowFilled)
          .disabled(!model.canChangeLocation)
        }
      }
    case .attached(let location, let phase):
      AttachedSummary(model: model, location: location, phase: phase)
    case .moving(let journal):
      MovingSummary(model: model, journal: journal)
    }
  }

  private func text(for work: SyncSettingsModel.Work) -> Text {
    switch work {
    case .disconnecting: Text("Turning sync off once the sync in progress ends…", tableName: "SyncSettings", bundle: .module)
    case .continuingMove: Text("Moving your \(app.vaultNoun). Keep \(app.displayName) open until it is done…", tableName: "SyncSettings", bundle: .module)
    case .abandoningMove: Text("Abandoning the move…", tableName: "SyncSettings", bundle: .module)
    case .staying: Text("Staying at this location…", tableName: "SyncSettings", bundle: .module)
    }
  }
}

private struct AttachedSummary: View {
  @Environment(\.appIdentity) private var app
  let model: SyncSettingsModel
  let location: SyncLocation
  let phase: SyncPhase?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ShadowLabeledContent(title: Text("Storage", tableName: "SyncSettings", bundle: .module)) {
        Label {
          Text(verbatim: SyncProviderOption.name(of: location.kind))
        } icon: {
          Image(systemName: SyncProviderOption.systemImage(of: location.kind))
        }
      }
      ShadowLabeledContent(title: Text("Location", tableName: "SyncSettings", bundle: .module)) {
        Text(verbatim: SyncLocationText(app: app).place(location.settings)).textSelection(.enabled).multilineTextAlignment(.trailing)
      }
      ShadowLabeledContent(title: Text(verbatim: app.vaultTitle)) {
        Text(verbatim: location.vault.rawValue).shadowFont(.caption).monospaced().textSelection(.enabled)
      }
      ShadowLabeledContent(title: Text("Status", tableName: "SyncSettings", bundle: .module)) { status }
      if let advice = SyncLocationText(app: app).advice(phase) {
        Text(verbatim: advice).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if !model.sync.canMoveVault {
        Text(verbatim: SyncSettingsErrors(app: app).routedMoveText).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if model.connect == nil, model.confirmation == nil {
        HStack(spacing: Spacing.space2) {
          Spacer(minLength: Spacing.space3)
          if phase?.canMove == true, model.sync.canMoveVault {
            Button {
              model.startMove()
            } label: {
              Text("Move to Another Storage…", tableName: "SyncSettings", bundle: .module)
            }
            .buttonStyle(.shadowBordered)
            .disabled(!model.canChangeLocation)
          }
          Button(role: .destructive) {
            model.confirm(.disconnect)
          } label: {
            Text("Disconnect…", tableName: "SyncSettings", bundle: .module)
          }
          .buttonStyle(.shadowBordered)
          .disabled(model.work != nil)
        }
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    if let indicator = SyncIndicator(model.sync.status, deviceNames: model.sync.deviceNames, scope: model.sync.attentionScope, app: model.sync.identity) {
      VStack(alignment: .trailing, spacing: Spacing.space05) {
        Text(verbatim: indicator.headline)
        Text(verbatim: indicator.detail).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).multilineTextAlignment(.trailing)
        if let scope = indicator.scope {
          Text(verbatim: scope).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).multilineTextAlignment(.trailing)
        }
      }
    } else {
      Text("Starting", tableName: "SyncSettings", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

private struct MovingSummary: View {
  @Environment(\.appIdentity) private var app
  let model: SyncSettingsModel
  let journal: SyncMoveJournal?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text(verbatim: headline).foregroundStyle(ShadowColor.textPrimary)
      Text(
        "Nothing syncs until it finishes or you abandon it. Abandoning keeps your \(app.vaultNoun) syncing where it was; anything already copied stays at the new location.",
        tableName: "SyncSettings", bundle: .module
      )
      .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      if model.confirmation == nil {
        HStack(spacing: Spacing.space2) {
          Spacer(minLength: Spacing.space3)
          Button(role: .destructive) {
            model.confirm(.abandonMove)
          } label: {
            Text("Abandon Move…", tableName: "SyncSettings", bundle: .module)
          }
          .buttonStyle(.shadowBordered)
          .disabled(model.work != nil)
          if journal != nil {
            Button {
              Task { await model.continueMove() }
            } label: {
              Text("Continue Move", tableName: "SyncSettings", bundle: .module)
            }
            .buttonStyle(.shadowFilled)
            .disabled(model.work != nil || model.isKeychainRefused)
          }
        }
      }
    }
  }

  private var headline: String {
    switch journal {
    case .movingOut(_, let target)?:
      String(localized: "Moving your \(app.vaultNoun) to \(SyncProviderOption.name(of: target.kind)) has not finished.", table: "SyncSettings", bundle: .module)
    case .following(_, let target)?:
      String(localized: "Following your \(app.vaultNoun) to \(SyncProviderOption.name(of: target.kind)) has not finished.", table: "SyncSettings", bundle: .module)
    case nil: String(localized: "A move of your \(app.vaultNoun) was started on this device, but its record cannot be read.", table: "SyncSettings", bundle: .module)
    }
  }
}

private struct MoveNoticeSection: View {
  @Environment(\.appIdentity) private var app
  let model: SyncSettingsModel
  let notice: VaultMoveNotice

  var body: some View {
    ShadowCallout(
      Text(verbatim: headline),
      message: Text(
        "This device sends nothing more here. Follow the move to keep syncing with your other devices, or stay here; a device that stays no longer sees their changes.",
        tableName: "SyncSettings", bundle: .module), intent: .warning, systemImage: "arrow.right.circle"
    ) {
      if model.confirmation == nil {
        Button {
          Task { await model.startFollow(notice) }
        } label: {
          Text("Follow Move", tableName: "SyncSettings", bundle: .module)
        }
        .disabled(!model.canChangeLocation || !model.sync.canMoveVault)
        Button {
          model.confirm(.stayAfterMove)
        } label: {
          Text("Stay Here…", tableName: "SyncSettings", bundle: .module)
        }
        .disabled(model.work != nil)
      }
    }
  }

  private var headline: String {
    guard let kind = notice.targetLocation?.kind else { return String(localized: "Another device moved your \(app.vaultNoun).", table: "SyncSettings", bundle: .module) }
    return String(localized: "Another device moved your \(app.vaultNoun) to \(SyncProviderOption.name(of: kind)).", table: "SyncSettings", bundle: .module)
  }
}

private struct ConfirmationCallout: View {
  @Environment(\.appIdentity) private var app
  let model: SyncSettingsModel
  let confirmation: SyncSettingsModel.Confirmation

  var body: some View {
    ShadowCallout(title, message: message, intent: .warning, systemImage: "questionmark.circle") {
      Button {
        model.confirmation = nil
      } label: {
        Text("Cancel", tableName: "SyncSettings", bundle: .module)
      }
      Button(role: .destructive) {
        Task { await act() }
      } label: {
        confirmLabel
      }
    }
  }

  private func act() async {
    switch confirmation {
    case .disconnect: await model.disconnect()
    case .abandonMove: await model.abandonMove()
    case .stayAfterMove: await model.stayAfterMove()
    }
  }

  private var title: Text {
    switch confirmation {
    case .disconnect: Text("Turn off sync on this device?", tableName: "SyncSettings", bundle: .module)
    case .abandonMove: Text("Abandon the move?", tableName: "SyncSettings", bundle: .module)
    case .stayAfterMove: Text("Stay at the old location?", tableName: "SyncSettings", bundle: .module)
    }
  }

  private var message: Text {
    switch confirmation {
    case .disconnect:
      Text(
        "Your \(app.vaultNoun) stays on this device, and its synced copy and keys stay where they are, so your other devices keep syncing. This device stops sending and receiving changes until you turn sync on again.",
        tableName: "SyncSettings", bundle: .module)
    case .abandonMove:
      Text(
        "Your \(app.vaultNoun) keeps syncing where it was. What the move already copied stays at the new location, which then no longer counts as empty.",
        tableName: "SyncSettings", bundle: .module)
    case .stayAfterMove:
      Text(
        "This device keeps syncing at the old location, but it no longer sees changes from devices that followed the move, and they no longer see its changes.",
        tableName: "SyncSettings", bundle: .module)
    }
  }

  private var confirmLabel: Text {
    switch confirmation {
    case .disconnect: Text("Disconnect", tableName: "SyncSettings", bundle: .module)
    case .abandonMove: Text("Abandon Move", tableName: "SyncSettings", bundle: .module)
    case .stayAfterMove: Text("Stay Here", tableName: "SyncSettings", bundle: .module)
    }
  }
}

private struct NoticeCallout: View {
  @Environment(\.appIdentity) private var app
  let notice: SyncSettingsModel.Notice

  var body: some View {
    ShadowCallout(text, intent: .success, systemImage: "checkmark.circle") { EmptyView() }
  }

  private var text: Text {
    switch notice {
    case .disconnected: Text("Sync is off on this device. Your \(app.vaultNoun) is still here.", tableName: "SyncSettings", bundle: .module)
    case .moveAbandoned: Text("The move was abandoned. Your \(app.vaultNoun) syncs where it did.", tableName: "SyncSettings", bundle: .module)
    case .stayed: Text("This device stays at the old location.", tableName: "SyncSettings", bundle: .module)
    }
  }
}

struct WorkingRow: View {
  let text: Text

  var body: some View {
    HStack(spacing: Spacing.space2) {
      ProgressView().controlSize(.small)
      text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

extension SyncPhase {
  /// A move starts only from a vault the runtime can hand an engine for.
  fileprivate var canMove: Bool {
    guard case .vault = self else { return false }
    return true
  }
}
