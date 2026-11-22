import ShadowDesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// Share Diagnostics: what the file holds and never holds, then prepare it on this device and save or share it.
struct DiagnosticsView: View {
  private let identity: AppIdentity
  @State private var model: DiagnosticsModel
  @State private var showsSummary = false

  init(identity: AppIdentity, model: DiagnosticsModel) {
    self.identity = identity
    _model = State(initialValue: model)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space5) {
        Text(
          "If something goes wrong, this file helps work out why. \(identity.displayName) builds it on this device, and it goes only where you save or share it.",
          tableName: "Diagnostics", bundle: .module
        )
        .fixedSize(horizontal: false, vertical: true)
        contentsSection
        stageSection
      }
      .padding(Spacing.space4)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .shadowScreen(.pushed)
    .navigationTitle(Text("Share Diagnostics", tableName: "Diagnostics", bundle: .module))
    .environment(\.appIdentity, identity)
    .onAppear { model.appeared() }
    .onDisappear { model.disappeared() }
    .fileExporter(
      isPresented: $model.isSaving, item: model.file, contentTypes: [.zip], defaultFilename: model.file?.url.lastPathComponent,
      onCompletion: { model.saved($0) })
  }

  private var contentsSection: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        line("info.circle", Text("The app's version, the system's version and the kind of device", tableName: "Diagnostics", bundle: .module))
        line(
          "arrow.triangle.2.circlepath",
          Text("Whether sync is on, the kind of storage, and each store's sync state, counts and error codes", tableName: "Diagnostics", bundle: .module))
        line("sparkles", Text("The AI provider you chose, whether a key is saved, and which kinds of data you allowed", tableName: "Diagnostics", bundle: .module))
        line("internaldrive", Text("The size of your \(identity.vaultNoun) on this device and its format versions", tableName: "Diagnostics", bundle: .module))
        line("number", Text("Counts \(identity.displayName) keeps about its own work", tableName: "Diagnostics", bundle: .module))
        line(
          "doc.text",
          Text(
            "Technical log lines since \(identity.displayName) last opened, at most the last 24 hours, with personal values hidden", tableName: "Diagnostics",
            bundle: .module))
      }
      .padding(Spacing.space3)
    } header: {
      Text("What the file holds", tableName: "Diagnostics", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "Never your \(identity.vaultNoun)'s content, names you gave, file or folder names, keys, passwords, tokens or your email address.",
        tableName: "Diagnostics", bundle: .module)
    }
  }

  private func line(_ systemImage: String, _ text: Text) -> some View {
    Label {
      text.fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private var stageSection: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        switch model.stage {
        case .idle:
          prepareButton(Text("Prepare the File", tableName: "Diagnostics", bundle: .module))
        case .preparing:
          HStack(spacing: Spacing.space3) {
            ProgressView()
            Text("Collecting the details.", tableName: "Diagnostics", bundle: .module)
          }
        case .ready(let archive):
          ready(archive)
        case .failed(let error):
          ShadowCallout(Text("Did not finish", tableName: "Diagnostics", bundle: .module), message: error.text, intent: .warning)
          prepareButton(Text("Try Again", tableName: "Diagnostics", bundle: .module))
        }
      }
      .padding(Spacing.space3)
    } header: {
      Text("The file", tableName: "Diagnostics", bundle: .module).shadowFont(.headline)
    } footer: {
      Text(
        "The copy waiting here is removed when you clear it, leave this screen or next open \(identity.displayName).", tableName: "Diagnostics",
        bundle: .module)
    }
  }

  @ViewBuilder
  private func ready(_ archive: DiagnosticsArchive) -> some View {
    ShadowBadge(Text("Ready", tableName: "Diagnostics", bundle: .module), intent: .success)
    Text(verbatim: archive.fileName).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
    HStack(spacing: Spacing.space3) {
      Button {
        model.isSaving = true
      } label: {
        Text("Save…", tableName: "Diagnostics", bundle: .module)
      }
      .buttonStyle(.shadowFilled)
      if let file = model.file {
        ShareLink(item: file, preview: SharePreview(Text(verbatim: archive.fileName))) {
          Text("Share…", tableName: "Diagnostics", bundle: .module)
        }
      }
    }
    if let failure = model.saveFailure { ShadowValidationMessage(failure.text) }
    DisclosureGroup(isExpanded: $showsSummary) {
      Text(verbatim: archive.summary)
        .shadowFont(.monoBody)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Text("Show the Summary", tableName: "Diagnostics", bundle: .module)
    }
    Button(role: .destructive) {
      model.clear()
    } label: {
      Text("Clear", tableName: "Diagnostics", bundle: .module)
    }
  }

  private func prepareButton(_ title: Text) -> some View {
    Button {
      Task { await model.prepare() }
    } label: {
      title
    }
    .buttonStyle(.shadowFilled)
  }
}

/// The About screen's way to Share Diagnostics, shown when the app passed its sources with `diagnostics(_:)`.
struct DiagnosticsAboutSection: View {
  let identity: AppIdentity
  let version: AppVersion
  let sources: DiagnosticsSources

  var body: some View {
    ShadowGroupedSection {
      NavigationLink {
        DiagnosticsView(identity: identity, model: DiagnosticsModel(builder: .live(identity: identity, version: version, sources: sources)))
      } label: {
        ShadowListRow(title: Text("Share Diagnostics", tableName: "Diagnostics", bundle: .module), accessory: .chevron) {
          Image(systemName: "stethoscope").foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .buttonStyle(.shadowRow)
    } footer: {
      Text(
        "A file of technical details to send with a support request. It never holds your \(identity.vaultNoun)'s content, your keys or anything that names you.",
        tableName: "Diagnostics", bundle: .module)
    }
  }
}

#Preview {
  let identity = AppIdentity(id: "com.shadow.apps.preview", displayName: "Preview", vaultNoun: "library", vaultTitle: "Library", exampleBucketName: "my-preview")
  NavigationStack {
    DiagnosticsView(
      identity: identity,
      model: DiagnosticsModel(builder: .live(identity: identity, version: AppVersion(version: "1.0", build: "42"), sources: DiagnosticsSources())))
  }
  .shadowTheme()
}
