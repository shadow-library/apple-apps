import ShadowDesignSystem
import ShadowSync
import ShadowSyncRuntime
import SwiftUI
import UniformTypeIdentifiers

struct SyncConnectView: View {
  @Environment(\.appIdentity) private var app
  let model: SyncConnectModel
  let close: () -> Void

  var body: some View {
    @Bindable var model = model
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let failure = model.failure { ShadowValidationMessage(failure.text) }
        content
        footer
      }
      .padding(Spacing.space3)
    } header: {
      title.shadowFont(.headline)
    }
    .fileImporter(isPresented: $model.isImporterPresented, allowedContentTypes: [.folder]) { result in
      Task { await model.folderPicked(result) }
    }
    .fileDialogMessage(Text("Choose the folder your \(app.vaultNoun) syncs with.", tableName: "SyncSettings", bundle: .module))
    .fileDialogConfirmationLabel(Text("Choose", tableName: "SyncSettings", bundle: .module))
  }

  private var title: Text {
    switch model.purpose {
    case .connect: Text("Turn On Sync", tableName: "SyncSettings", bundle: .module)
    case .move: Text("Move to Another Storage", tableName: "SyncSettings", bundle: .module)
    case .follow: Text("Follow the Move", tableName: "SyncSettings", bundle: .module)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.step {
    case .choosing:
      choosing
    case .s3Form:
      SyncS3FormView(model: model)
    case .working(let work):
      WorkingRow(text: text(for: work))
    case .discovered(let settings, let discovery):
      DiscoveryView(model: model, settings: settings, discovery: discovery)
    case .confirmingMove(let settings):
      MoveConfirmation(model: model, settings: settings)
    case .finished(let finish):
      FinishedView(finish: finish)
    }
  }

  @ViewBuilder
  private var choosing: some View {
    if case .follow(let target) = model.purpose {
      FollowHint(target: target) { model.isImporterPresented = true }
    } else {
      Text(prompt).foregroundStyle(ShadowColor.textSecondary)
      ForEach(model.options) { option in ProviderRow(option: option) { Task { await model.choose(option.kind) } } }
    }
  }

  private var prompt: LocalizedStringResource {
    model.purpose == .move
      ? LocalizedStringResource(
        "Choose an empty storage location. Your \(app.vaultNoun) is copied there whole, checked, and then syncs there.", table: "SyncSettings", bundle: .module)
      : LocalizedStringResource("Choose where your \(app.vaultNoun) syncs. It is encrypted on this device before anything leaves it.", table: "SyncSettings", bundle: .module)
  }

  @ViewBuilder
  private var footer: some View {
    HStack(spacing: Spacing.space2) {
      if model.purpose == .move || model.purpose == .connect, Self.showsBack(model.step) {
        Button {
          model.back()
        } label: {
          Text("Back", tableName: "SyncSettings", bundle: .module)
        }
        .buttonStyle(.shadowBordered)
      }
      Spacer(minLength: Spacing.space3)
      if Self.isFinished(model.step) {
        Button(action: close) {
          Text("Done", tableName: "SyncSettings", bundle: .module)
        }
        .buttonStyle(.shadowFilled)
      } else {
        Button(action: close) {
          Text("Cancel", tableName: "SyncSettings", bundle: .module)
        }
        .buttonStyle(.shadowBordered)
        .disabled(model.isWorking)
      }
    }
  }

  private static func showsBack(_ step: SyncConnectModel.Step) -> Bool {
    switch step {
    case .s3Form, .discovered, .confirmingMove: true
    case .choosing, .working, .finished: false
    }
  }

  private static func isFinished(_ step: SyncConnectModel.Step) -> Bool {
    guard case .finished = step else { return false }
    return true
  }

  private func text(for work: SyncConnectModel.Work) -> Text {
    switch work {
    case .checking: Text("Looking at the storage…", tableName: "SyncSettings", bundle: .module)
    case .attaching: Text("Turning on sync…", tableName: "SyncSettings", bundle: .module)
    case .moving: Text("Moving your \(app.vaultNoun). This can take a while; keep \(app.displayName) open until it is done…", tableName: "SyncSettings", bundle: .module)
    case .following: Text("Following the move…", tableName: "SyncSettings", bundle: .module)
    }
  }
}

private struct ProviderRow: View {
  @Environment(\.appIdentity) private var app
  let option: SyncProviderOption
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
        Image(systemName: option.systemImage).frame(width: Spacing.space5)
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text(verbatim: option.name).foregroundStyle(option.isAvailable ? ShadowColor.textPrimary : ShadowColor.textSecondary)
          Text(verbatim: option.reason(app: app) ?? option.summary).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        Spacer(minLength: Spacing.space2)
        if option.isAvailable { Image(systemName: "chevron.right").foregroundStyle(ShadowColor.textTertiary) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!option.isAvailable)
    .accessibilityHint(option.reason(app: app).map { Text(verbatim: $0) } ?? Text(verbatim: option.summary))
  }
}

private struct FollowHint: View {
  @Environment(\.appIdentity) private var app
  let target: SyncProviderSettings
  let choose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if case .localFolder(let folder) = target {
        Text("Choose the folder your \(app.vaultNoun) moved to on this device.", tableName: "SyncSettings", bundle: .module)
        Text("On the device that moved it, it is \(folder.path).", tableName: "SyncSettings", bundle: .module).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          .textSelection(.enabled)
        HStack {
          Spacer(minLength: Spacing.space3)
          Button(action: choose) {
            Text("Choose Folder…", tableName: "SyncSettings", bundle: .module)
          }
          .buttonStyle(.shadowFilled)
        }
      }
    }
  }
}

private struct DiscoveryView: View {
  @Environment(\.appIdentity) private var app
  let model: SyncConnectModel
  let settings: SyncProviderSettings
  let discovery: VaultDiscovery

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text(verbatim: SyncLocationText(app: app).place(settings)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
      if model.conditionalWritesUnsupported {
        ShadowCallout(
          Text("This storage cannot refuse a second writer.", tableName: "SyncSettings", bundle: .module),
          message: Text(
            "Turn on sync on one device at a time here, so two devices never set up a \(app.vaultNoun) at the same moment.", tableName: "SyncSettings", bundle: .module),
          intent: .warning
        ) { EmptyView() }
      }
      switch discovery {
      case .empty:
        Text("No \(app.vaultNoun) syncs here yet. Create one with the \(app.vaultNoun) on this device.", tableName: "SyncSettings", bundle: .module)
        action(Text("Create a Vault Here", tableName: "SyncSettings", bundle: .module)) { await model.attach(.create) }
      case .found(let vault):
        Text("A synced \(app.vaultNoun) is already here. Joining it merges your \(app.vaultNoun) on this device into it.", tableName: "SyncSettings", bundle: .module)
        Text(verbatim: vault.rawValue).shadowFont(.caption).monospaced().foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
        action(Text("Join the Vault Found Here", tableName: "SyncSettings", bundle: .module)) { await model.attach(.join(vault)) }
      case .newerFormat:
        ShadowValidationMessage(Text(verbatim: SyncSettingsErrors(app: app).newerFormatHeadline))
      case .unrecognized:
        ShadowValidationMessage(Text(verbatim: SyncSettingsErrors(app: app).unrecognizedHeadline))
      }
    }
  }

  private func action(_ label: Text, _ perform: @escaping () async -> Void) -> some View {
    HStack {
      Spacer(minLength: Spacing.space3)
      Button {
        Task { await perform() }
      } label: {
        label
      }
      .buttonStyle(.shadowFilled)
    }
  }
}

private struct MoveConfirmation: View {
  @Environment(\.appIdentity) private var app
  let model: SyncConnectModel
  let settings: SyncProviderSettings

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("Move your \(app.vaultNoun) to \(SyncProviderOption.name(of: settings.kind))?", tableName: "SyncSettings", bundle: .module).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: SyncLocationText(app: app).place(settings)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
      if model.conditionalWritesUnsupported {
        ShadowCallout(
          Text("This storage cannot refuse a second writer.", tableName: "SyncSettings", bundle: .module),
          message: Text("Move from one device only, and let the others follow.", tableName: "SyncSettings", bundle: .module), intent: .warning
        ) { EmptyView() }
      }
      Text(
        "This device first sends its latest changes, then copies the whole \(app.vaultNoun) there and reads it back to check it. Your other devices follow the move when they next sync. The old location is kept until you remove it yourself.",
        tableName: "SyncSettings", bundle: .module
      )
      .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      HStack {
        Spacer(minLength: Spacing.space3)
        Button {
          Task { await model.move() }
        } label: {
          Text("Move \(app.vaultTitle)", tableName: "SyncSettings", bundle: .module)
        }
        .buttonStyle(.shadowFilled)
      }
    }
  }
}

private struct FinishedView: View {
  @Environment(\.appIdentity) private var app
  let finish: SyncConnectModel.Finish

  var body: some View {
    ShadowCallout(text, intent: intent, systemImage: intent == .success ? "checkmark.circle" : "arrow.right.circle") { EmptyView() }
  }

  private var intent: ShadowIntent {
    if case .superseded = finish { return .warning }
    return .success
  }

  private var text: Text {
    switch finish {
    case .attached(.vault(.awaitingKey)):
      Text("Sync is on. This device waits for your \(app.vaultNoun)'s key from one of your other devices.", tableName: "SyncSettings", bundle: .module)
    case .attached: Text("Sync is on.", tableName: "SyncSettings", bundle: .module)
    case .moved(let location):
      Text(
        "Your \(app.vaultNoun) now syncs with \(SyncProviderOption.name(of: location.kind)). The old location is kept until you remove it.", tableName: "SyncSettings",
        bundle: .module)
    case .superseded: Text("Another device moved your \(app.vaultNoun) first. Follow its move instead.", tableName: "SyncSettings", bundle: .module)
    }
  }
}
