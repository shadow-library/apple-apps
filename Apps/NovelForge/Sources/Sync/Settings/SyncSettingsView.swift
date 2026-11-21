import ShadowDesignSystem
import ShadowSync
import ShadowSyncRuntime
import SwiftUI

struct SyncSettingsView: View {
  @State private var model: SyncSettingsModel
  @State private var isShowingKeys = false

  init(sync: SyncRuntimes) {
    _model = State(initialValue: SyncSettingsModel(sync: sync))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if model.isKeychainRefused { TeamlessCallout() }
        SyncLocationSection(model: model)
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
    .onChange(of: model.sync.status) { Task { await model.refresh() } }
    .navigationDestination(isPresented: $isShowingKeys) { SyncKeysSettingsView() }
    .onDisappear { if !isShowingKeys { model.leave() } }
  }

  private var keysSection: some View {
    ShadowGroupedSection {
      Button {
        isShowingKeys = true
      } label: {
        Label {
          Text("Keys and Devices", tableName: "SyncSettings")
        } icon: {
          Image(systemName: "key")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(Spacing.space3)
    } header: {
      Text("Keys", tableName: "SyncSettings").shadowFont(.headline)
    } footer: {
      Text("Your library is encrypted with keys that stay on your devices. The recovery phrase and your other devices are managed here.", tableName: "SyncSettings")
    }
  }
}

private struct TeamlessCallout: View {
  var body: some View {
    ShadowCallout(
      Text(verbatim: SyncSettingsErrors.teamlessHeadline),
      message: Text(
        "Sync keeps your library's keys in the keychain, and the system refuses the keychain to a build signed without a development team. Use a build signed with a team to sync on this device.",
        tableName: "SyncSettings"), intent: .danger, systemImage: "lock.trianglebadge.exclamationmark"
    ) { EmptyView() }
  }
}

private struct SyncLocationSection: View {
  let model: SyncSettingsModel

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        if let notice = model.notice { NoticeCallout(notice: notice) }
        content
        if let work = model.work { WorkingRow(text: Self.text(for: work)) }
        if let confirmation = model.confirmation { ConfirmationCallout(model: model, confirmation: confirmation) }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Sync", tableName: "SyncSettings").shadowFont(.headline)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.overview {
    case .loading:
      ProgressView().frame(maxWidth: .infinity)
    case .unavailable:
      Text("Sync settings are available once your library is open.", tableName: "SyncSettings").foregroundStyle(ShadowColor.textSecondary)
    case .unreadable(let error):
      error.text.foregroundStyle(ShadowColor.textSecondary)
    case .off(let reason):
      Text(verbatim: SyncLocationText.offReason(reason)).foregroundStyle(ShadowColor.textSecondary)
      if reason != .newerFormat, model.connect == nil {
        HStack {
          Spacer(minLength: Spacing.space3)
          Button {
            model.startConnect()
          } label: {
            Text("Turn On Sync", tableName: "SyncSettings")
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

  private static func text(for work: SyncSettingsModel.Work) -> Text {
    switch work {
    case .disconnecting: Text("Turning sync off once the sync in progress ends…", tableName: "SyncSettings")
    case .continuingMove: Text("Moving your library. Keep Novel Forge open until it is done…", tableName: "SyncSettings")
    case .abandoningMove: Text("Abandoning the move…", tableName: "SyncSettings")
    case .staying: Text("Staying at this location…", tableName: "SyncSettings")
    }
  }
}

private struct AttachedSummary: View {
  let model: SyncSettingsModel
  let location: SyncLocation
  let phase: SyncPhase?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ShadowLabeledContent(title: Text("Storage", tableName: "SyncSettings")) {
        Label {
          Text(verbatim: SyncProviderOption.name(of: location.kind))
        } icon: {
          Image(systemName: SyncProviderOption.systemImage(of: location.kind))
        }
      }
      ShadowLabeledContent(title: Text("Location", tableName: "SyncSettings")) {
        Text(verbatim: SyncLocationText.place(location.settings)).textSelection(.enabled).multilineTextAlignment(.trailing)
      }
      ShadowLabeledContent(title: Text("Library", tableName: "SyncSettings")) {
        Text(verbatim: location.vault.rawValue).shadowFont(.caption).monospaced().textSelection(.enabled)
      }
      ShadowLabeledContent(title: Text("Status", tableName: "SyncSettings")) { status }
      if let advice = SyncLocationText.advice(phase) {
        Text(verbatim: advice).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if model.connect == nil, model.confirmation == nil {
        HStack(spacing: Spacing.space2) {
          Spacer(minLength: Spacing.space3)
          if phase?.canMove == true {
            Button {
              model.startMove()
            } label: {
              Text("Move to Another Storage…", tableName: "SyncSettings")
            }
            .buttonStyle(.shadowBordered)
            .disabled(!model.canChangeLocation)
          }
          Button(role: .destructive) {
            model.confirm(.disconnect)
          } label: {
            Text("Disconnect…", tableName: "SyncSettings")
          }
          .buttonStyle(.shadowBordered)
          .disabled(model.work != nil)
        }
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    if let indicator = SyncIndicator(model.sync.status, deviceNames: model.sync.deviceNames) {
      VStack(alignment: .trailing, spacing: Spacing.space05) {
        Text(verbatim: indicator.headline)
        Text(verbatim: indicator.detail).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).multilineTextAlignment(.trailing)
      }
    } else {
      Text("Starting", tableName: "SyncSettings").foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

private struct MovingSummary: View {
  let model: SyncSettingsModel
  let journal: SyncMoveJournal?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      Text(verbatim: headline).foregroundStyle(ShadowColor.textPrimary)
      Text(
        "Nothing syncs until it finishes or you abandon it. Abandoning keeps your library syncing where it was; anything already copied stays at the new location.",
        tableName: "SyncSettings"
      )
      .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      if model.confirmation == nil {
        HStack(spacing: Spacing.space2) {
          Spacer(minLength: Spacing.space3)
          Button(role: .destructive) {
            model.confirm(.abandonMove)
          } label: {
            Text("Abandon Move…", tableName: "SyncSettings")
          }
          .buttonStyle(.shadowBordered)
          .disabled(model.work != nil)
          if journal != nil {
            Button {
              Task { await model.continueMove() }
            } label: {
              Text("Continue Move", tableName: "SyncSettings")
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
      String(localized: "Moving your library to \(SyncProviderOption.name(of: target.kind)) has not finished.", table: "SyncSettings")
    case .following(_, let target)?:
      String(localized: "Following your library to \(SyncProviderOption.name(of: target.kind)) has not finished.", table: "SyncSettings")
    case nil: String(localized: "A move of your library was started on this device, but its record cannot be read.", table: "SyncSettings")
    }
  }
}

private struct MoveNoticeSection: View {
  let model: SyncSettingsModel
  let notice: VaultMoveNotice

  var body: some View {
    ShadowCallout(
      Text(verbatim: headline),
      message: Text(
        "This device sends nothing more here. Follow the move to keep syncing with your other devices, or stay here; a device that stays no longer sees their changes.",
        tableName: "SyncSettings"), intent: .warning, systemImage: "arrow.right.circle"
    ) {
      if model.confirmation == nil {
        Button {
          Task { await model.startFollow(notice) }
        } label: {
          Text("Follow Move", tableName: "SyncSettings")
        }
        .disabled(!model.canChangeLocation)
        Button {
          model.confirm(.stayAfterMove)
        } label: {
          Text("Stay Here…", tableName: "SyncSettings")
        }
        .disabled(model.work != nil)
      }
    }
  }

  private var headline: String {
    guard let kind = notice.targetLocation?.kind else { return String(localized: "Another device moved your library.", table: "SyncSettings") }
    return String(localized: "Another device moved your library to \(SyncProviderOption.name(of: kind)).", table: "SyncSettings")
  }
}

private struct ConfirmationCallout: View {
  let model: SyncSettingsModel
  let confirmation: SyncSettingsModel.Confirmation

  var body: some View {
    ShadowCallout(title, message: message, intent: .warning, systemImage: "questionmark.circle") {
      Button {
        model.confirmation = nil
      } label: {
        Text("Cancel", tableName: "SyncSettings")
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
    case .disconnect: Text("Turn off sync on this device?", tableName: "SyncSettings")
    case .abandonMove: Text("Abandon the move?", tableName: "SyncSettings")
    case .stayAfterMove: Text("Stay at the old location?", tableName: "SyncSettings")
    }
  }

  private var message: Text {
    switch confirmation {
    case .disconnect:
      Text(
        "Your library stays on this device, and its synced copy and keys stay where they are, so your other devices keep syncing. This device stops sending and receiving changes until you turn sync on again.",
        tableName: "SyncSettings")
    case .abandonMove:
      Text("Your library keeps syncing where it was. What the move already copied stays at the new location, which then no longer counts as empty.", tableName: "SyncSettings")
    case .stayAfterMove:
      Text(
        "This device keeps syncing at the old location, but it no longer sees changes from devices that followed the move, and they no longer see its changes.",
        tableName: "SyncSettings")
    }
  }

  private var confirmLabel: Text {
    switch confirmation {
    case .disconnect: Text("Disconnect", tableName: "SyncSettings")
    case .abandonMove: Text("Abandon Move", tableName: "SyncSettings")
    case .stayAfterMove: Text("Stay Here", tableName: "SyncSettings")
    }
  }
}

private struct NoticeCallout: View {
  let notice: SyncSettingsModel.Notice

  var body: some View {
    ShadowCallout(text, intent: .success, systemImage: "checkmark.circle") { EmptyView() }
  }

  private var text: Text {
    switch notice {
    case .disconnected: Text("Sync is off on this device. Your library is still here.", tableName: "SyncSettings")
    case .moveAbandoned: Text("The move was abandoned. Your library syncs where it did.", tableName: "SyncSettings")
    case .stayed: Text("This device stays at the old location.", tableName: "SyncSettings")
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
