import ShadowCore
import ShadowDesignSystem
import ShadowSync
import ShadowSyncRuntime
import SwiftUI

/// Keys and Devices: reached from Sync Settings, and from the sync indicator while this device waits for the vault's key.
struct SyncKeysView: View {
  @State private var model: SyncKeysModel
  @Environment(\.scenePhase) private var scenePhase

  init(sync: SyncRuntimes, start: SyncKeysStart = .overview) {
    _model = State(initialValue: SyncKeysModel(sync: sync, start: start))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        if let notice = model.notice { NoticeCallout(notice: notice) }
        switch model.overview {
        case .loading:
          ProgressView().frame(maxWidth: .infinity)
        case .unavailable(let reason):
          Text(verbatim: reason).foregroundStyle(ShadowColor.textSecondary)
        case .ready(let keys):
          if let flow = model.flow {
            FlowView(flow: flow) { Task { await model.closeFlow() } }
          } else {
            KeysOverview(model: model, keys: keys)
          }
        }
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .background(ShadowColor.surfaceApp)
    .navigationTitle(Text("Keys and Devices", tableName: "SyncKeys", bundle: .module))
    .task(id: model.sync.runtime.map(ObjectIdentifier.init)) { await model.refresh() }
    .task(id: model.isWaitingForKey) { await model.watchForKey() }
    .onChange(of: model.sync.status) { Task { await model.refresh(holders: false) } }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.checkForKey() } }
    }
    .onDisappear { model.leave() }
    .environment(\.appIdentity, model.sync.identity)
  }
}

private struct FlowView: View {
  let flow: SyncKeysModel.Flow
  let close: () -> Void

  var body: some View {
    switch flow {
    case .setup(let model): RecoveryPhraseSetupView(model: model, close: close)
    case .recover(let model): PhraseRecoveryView(model: model, close: close)
    case .request(let model): KeyRequestView(model: model, close: close)
    case .respond(let model): KeyResponseView(model: model, close: close)
    }
  }
}

private struct KeysOverview: View {
  let model: SyncKeysModel
  let keys: SyncKeysModel.Keys

  var body: some View {
    if !keys.holdsKey {
      GetKeySection(model: model, isWaiting: true)
    } else {
      if model.lacksSomeKeys { GetKeySection(model: model, isWaiting: false) }
      RecoveryPhraseSection(model: model, keys: keys)
      SendKeySection(model: model)
      DevicesSection(keys: keys)
    }
  }
}

private struct GetKeySection: View {
  @Environment(\.appIdentity) private var app
  let model: SyncKeysModel
  let isWaiting: Bool

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if isWaiting {
          Label {
            Text("Waiting for this \(app.vaultNoun)'s key from your other devices", tableName: "SyncKeys", bundle: .module).foregroundStyle(ShadowColor.textPrimary)
          } icon: {
            ProgressView().controlSize(.small)
          }
          Text(
            "Your other devices hand the key to this one on their own, and \(app.displayName) keeps looking for it. You can also bring it here yourself.",
            tableName: "SyncKeys", bundle: .module
          )
          .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        } else {
          Text("Some of your \(app.vaultNoun)'s changes are sealed with a key that has not reached this device.", tableName: "SyncKeys", bundle: .module)
            .foregroundStyle(ShadowColor.textPrimary)
        }
        ShadowFlowLayout {
          Button {
            Task { await model.startRecovery() }
          } label: {
            Label {
              Text("Enter Recovery Phrase", tableName: "SyncKeys", bundle: .module)
            } icon: {
              Image(systemName: "text.word.spacing")
            }
          }
          .buttonStyle(.shadowBordered)
          Button {
            Task { await model.startRequest() }
          } label: {
            Label {
              Text("Scan from Another Device", tableName: "SyncKeys", bundle: .module)
            } icon: {
              Image(systemName: "qrcode.viewfinder")
            }
          }
          .buttonStyle(.shadowFilled)
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("This Device", tableName: "SyncKeys", bundle: .module).shadowFont(.headline)
    }
  }
}

private struct RecoveryPhraseSection: View {
  @Environment(\.appIdentity) private var app
  let model: SyncKeysModel
  let keys: SyncKeysModel.Keys
  @State private var isConfirmingNew = false

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let failure = keys.recoveryFailure { ShadowValidationMessage(failure.text) }
        standing
        if isConfirmingNew {
          ShadowCallout(
            Text("Make a new recovery phrase?", tableName: "SyncKeys", bundle: .module),
            message: Text("The phrase you have now stops working for your \(app.vaultNoun) once the new one is saved.", tableName: "SyncKeys", bundle: .module), intent: .warning,
            systemImage: "questionmark.circle"
          ) {
            Button {
              isConfirmingNew = false
            } label: {
              Text("Cancel", tableName: "SyncKeys", bundle: .module)
            }
            Button {
              isConfirmingNew = false
              Task { await model.startSetup() }
            } label: {
              Text("Make a New Phrase", tableName: "SyncKeys", bundle: .module)
            }
          }
        } else if let recovery = keys.recovery {
          HStack {
            Spacer(minLength: Spacing.space3)
            if recovery == .notSetUp {
              Button {
                Task { await model.startSetup() }
              } label: {
                Text("Set Up Recovery Phrase", tableName: "SyncKeys", bundle: .module)
              }
              .buttonStyle(.shadowFilled)
            } else {
              Button {
                isConfirmingNew = true
              } label: {
                Text("Make a New Phrase…", tableName: "SyncKeys", bundle: .module)
              }
              .buttonStyle(.shadowBordered)
            }
          }
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Recovery Phrase", tableName: "SyncKeys", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "A recovery phrase is 24 words that open your \(app.vaultNoun)'s keys on any device, for when none of your other devices is at hand.", tableName: "SyncKeys",
        bundle: .module)
    }
  }

  @ViewBuilder
  private var standing: some View {
    switch keys.recovery {
    case .notSetUp?:
      Text("No recovery phrase is set up. Without one, losing all your devices means losing your synced \(app.vaultNoun).", tableName: "SyncKeys", bundle: .module)
        .foregroundStyle(ShadowColor.textSecondary)
    case .active(let created)?:
      Text("A recovery phrase is set up, since \(Self.date(created)).", tableName: "SyncKeys", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
    case .replaced?:
      ShadowCallout(
        Text("Your recovery phrase was replaced on another device.", tableName: "SyncKeys", bundle: .module),
        message: Text(
          "The phrase you wrote down on this device no longer opens your \(app.vaultNoun)'s keys. Use the new phrase, or make a new one here.", tableName: "SyncKeys",
          bundle: .module),
        intent: .warning, systemImage: "exclamationmark.shield"
      ) { EmptyView() }
    case nil:
      if keys.recoveryFailure == nil { ProgressView().frame(maxWidth: .infinity) }
    }
  }

  private static func date(_ millis: Int64) -> String {
    Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .abbreviated, time: .omitted)
  }
}

private struct SendKeySection: View {
  @Environment(\.appIdentity) private var app
  let model: SyncKeysModel

  var body: some View {
    ShadowGroupedSection {
      Button {
        Task { await model.startResponse() }
      } label: {
        Label {
          Text("Send the Key to Another Device", tableName: "SyncKeys", bundle: .module)
        } icon: {
          Image(systemName: "qrcode")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(Spacing.space3)
    } header: {
      Text("Other Devices", tableName: "SyncKeys", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "For a device that is waiting for your \(app.vaultNoun)'s key: it shows a code, this device scans it, and the two compare six digits.", tableName: "SyncKeys",
        bundle: .module)
    }
  }
}

private struct DevicesSection: View {
  let keys: SyncKeysModel.Keys

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let failure = keys.holdingsFailure { ShadowValidationMessage(failure.text) }
        if let holdings = keys.holdings {
          ForEach(holdings, id: \.key) { holding in KeyHoldingRow(holding: holding, isOnly: holdings.count == 1) }
        } else if keys.holdingsFailure == nil {
          ProgressView().frame(maxWidth: .infinity)
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("Devices with the Key", tableName: "SyncKeys", bundle: .module).shadowFont(.headline)
    } footer: {
      Text("A device shows here once it has synced with a key. This device holds every key listed.", tableName: "SyncKeys", bundle: .module)
    }
  }
}

private struct KeyHoldingRow: View {
  let holding: SyncKeyHolding
  let isOnly: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if !isOnly { title.shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary) }
      if holding.holders.isEmpty {
        Text("No device has synced with this key yet.", tableName: "SyncKeys", bundle: .module).foregroundStyle(ShadowColor.textSecondary)
      }
      ForEach(holding.holders, id: \.replica) { holder in
        HStack(spacing: Spacing.space2) {
          Image(systemName: Self.symbol(holder.platform)).foregroundStyle(ShadowColor.textSecondary)
          Text(verbatim: Self.name(holder)).foregroundStyle(ShadowColor.textPrimary)
          Spacer(minLength: Spacing.space2)
          if holder.isThisDevice { ShadowBadge(Text("This Device", tableName: "SyncKeys", bundle: .module), intent: .accent) }
        }
      }
    }
  }

  private var title: Text {
    guard let created = holding.key.uuid.v7Timestamp else { return Text("Key \(Self.shortID(holding.key))", tableName: "SyncKeys", bundle: .module) }
    return Text("Key from \(created.formatted(date: .abbreviated, time: .omitted)) (\(Self.shortID(holding.key)))", tableName: "SyncKeys", bundle: .module)
  }

  private static func shortID(_ key: KeyID) -> String {
    String(key.description.suffix(6))
  }

  private static func name(_ holder: SyncKeyHolder) -> String {
    if let name = holder.name, !name.isEmpty { return name }
    if let platform = holder.platform, !platform.isEmpty { return platform }
    return String(localized: "Unnamed device", table: "SyncKeys", bundle: .module)
  }

  private static func symbol(_ platform: String?) -> String {
    switch platform {
    case "macOS": "laptopcomputer"
    case "iPadOS": "ipad"
    case "iOS": "iphone"
    default: "desktopcomputer"
    }
  }
}

private struct NoticeCallout: View {
  @Environment(\.appIdentity) private var app
  let notice: SyncKeysModel.Notice

  var body: some View {
    switch notice {
    case .keyArrived:
      ShadowCallout(Text("Your \(app.vaultNoun)'s key is on this device. Sync starts now.", tableName: "SyncKeys", bundle: .module), intent: .success, systemImage: "key") {
        EmptyView()
      }
    case .phraseSaved:
      ShadowCallout(Text("Your recovery phrase is saved.", tableName: "SyncKeys", bundle: .module), intent: .success, systemImage: "checkmark.shield") { EmptyView() }
    case .flowStopped(let reason):
      ShadowCallout(Text(verbatim: reason), intent: .warning, systemImage: "exclamationmark.triangle") { EmptyView() }
    }
  }
}
