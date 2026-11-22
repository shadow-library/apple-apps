import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// "Data export" (`features/settings/export-screen.tsx`): one archive with every record on this device, health data included, saved or shared by the
/// owner.
struct ExportView: View {
  @State private var model: ExportModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: ExportModel(context: context))
  }

  var body: some View {
    List {
      Section {
        Text("One archive with every record you have created, in formats you can open without this app. Exporting changes nothing.", tableName: "Data")
          .shadowFont(.subheadline)
        ShadowCallout(
          Text("The archive holds your health data and is not encrypted", tableName: "Data"),
          message: Text(
            "It includes everything Memoir keeps on this device, activity and health data too, as plain JSON with your receipt images beside it. Anyone who has the file can read it, so keep it somewhere only you can open.",
            tableName: "Data"),
          intent: .warning, systemImage: "lock.open")
      }
      stageSection
      VaultContentsSections(load: model.contents)
      Section {
        Text(
          "Memoir builds the archive on this device and hands it to you; nothing is uploaded. The copy waiting here is removed when you clear it, leave this screen or next open Memoir, so save or share it first. There is no library of past archives to keep — prepare a fresh one whenever you want.",
          tableName: "Data"
        )
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
      } header: {
        Text("Where the archive goes", tableName: "Data")
      }
    }
    .navigationTitle(Text("Data export", tableName: "Data"))
    .shadowScreen(.pushed)
    .task { await model.load() }
    .onAppear { model.appeared() }
    .onDisappear { model.disappeared() }
    .fileExporter(
      isPresented: $model.isSaving, item: model.file, contentTypes: [.zip], defaultFilename: model.file?.url.lastPathComponent,
      onCompletion: { model.saved($0) })
  }

  @ViewBuilder
  private var stageSection: some View {
    Section {
      switch model.stage {
      case .idle:
        prepareButton(Text("Prepare the export", tableName: "Data"))
        Text("Usually under a minute.", tableName: "Data").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      case .preparing:
        HStack(spacing: Spacing.space3) {
          ProgressView()
          Text("Collecting your records.", tableName: "Data")
        }
      case .ready(let archive):
        ready(archive)
      case .failed(let error):
        ShadowCallout(Text("Did not finish", tableName: "Data"), message: error.text, intent: .warning)
        prepareButton(Text("Try again", tableName: "Data"))
      }
    } header: {
      Text("Export everything", tableName: "Data")
    }
  }

  @ViewBuilder
  private func ready(_ archive: MemoirExportArchive) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      ShadowBadge(Text("Ready", tableName: "Data"), intent: .success)
      Text("A zip archive: your records as JSON, with your receipt images as files.", tableName: "Data")
      Text(verbatim: archive.fileName).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).textSelection(.enabled)
    }
    if archive.missingImages > 0 {
      LabeledContent {
        Text(archive.missingImages, format: .number)
      } label: {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          Text("Receipt images not on this device", tableName: "Data")
          Text("The archive lists these receipts without their image. Open each one on this device first to bring its image here.", tableName: "Data")
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
    Button {
      model.isSaving = true
    } label: {
      Text("Save the archive…", tableName: "Data")
    }
    .buttonStyle(.shadowFilled)
    if let file = model.file {
      ShareLink(item: file, preview: SharePreview(Text(verbatim: archive.fileName))) {
        Text("Share…", tableName: "Data")
      }
    }
    if let failure = model.saveFailure { ShadowValidationMessage(failure.text) }
    Button(role: .destructive) {
      model.clear()
    } label: {
      Text("Clear", tableName: "Data")
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

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      ExportView(context: context)
    }
    .shadowTheme()
  }
}
