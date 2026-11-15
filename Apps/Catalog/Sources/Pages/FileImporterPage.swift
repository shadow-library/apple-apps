import PhotosUI
@_spi(Preview) import ShadowDesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct FileImporterPage: View {
  struct Upload: Identifiable {
    let id = UUID()
    var name: String
    var size: String
    var symbol: String
    var state: ShadowTransferState
  }

  @State private var isImporting = false
  @State private var photo: PhotosPickerItem?
  @State private var uploads = [
    Upload(name: "cover-final.png", size: "2.4 MB", symbol: "photo", state: .uploading(progress: 0.62)),
    Upload(name: "story-bible.pdf", size: "180 KB", symbol: "doc.text", state: .done),
    Upload(name: "map-of-the-archive.tiff", size: "48 MB", symbol: "photo", state: .failed),
    Upload(name: "chapter-44-draft.docx", size: "96 KB", symbol: "doc.text", state: .queued),
  ]
  @State private var liveUploads: [Upload] = []

  private var supportsDrop: Bool {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom != .phone
    #else
      true
    #endif
  }

  private static let buttonWidth: CGFloat? = ShadowDensity.current == .touch ? .infinity : nil
  private static let types: [UTType] = [.png, .jpeg]

  var body: some View {
    ComponentPage(component: .fileImporter) {
      StateSection("Button", note: "A button opens Files; on iPhone Photos is one row away. State the accepted types and size before people pick.") {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          Button {
            isImporting = true
          } label: {
            Label("Choose cover image", systemImage: "photo").frame(maxWidth: Self.buttonWidth)
          }
          .buttonStyle(.shadowTinted)
          .controlSize(.large)
          #if os(iOS)
            PhotosPicker(selection: $photo, matching: .images) {
              Label("Choose from Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.shadowBordered)
            .controlSize(.large)
          #endif
          Text("PNG or JPEG, up to 10 MB").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        .shadowCard()
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.types) { _ in }
      }
      if supportsDrop {
        StateSection("Drop zone", note: "iPad and Mac accept drags. While a file hovers, the zone tints accent-soft and its dashed edge turns accent.") {
          VStack(spacing: Spacing.space3) {
            dropZone(targeted: nil)
            dropZone(targeted: true)
          }
          .shadowCard()
        }
      }
      StateSection(
        "Transfers", note: "Each row is one state: uploading with progress and Cancel, done, failed with a way to retry, and queued. Uploads continue if people leave the screen."
      ) {
        VStack(spacing: Spacing.space3) {
          ForEach($uploads) { $upload in
            ShadowFileRow(title: Text(verbatim: upload.name), detail: detail(for: upload), systemImage: upload.symbol, state: upload.state) {
              action(for: $upload)
            }
          }
        }
        .shadowCard()
      }
      if supportsDrop {
        StateSection("Try it", note: "Drop files on the zone, or tap it, to watch a simulated upload.") {
          VStack(spacing: Spacing.space3) {
            ShadowFileDropZone { urls in
              for url in urls { begin(url.lastPathComponent) }
              return !urls.isEmpty
            } content: { isTargeted in
              #if os(macOS)
                zoneLabel(isTargeted: isTargeted) { begin("new-cover.png") }
              #else
                Button {
                  begin("new-cover.png")
                } label: {
                  zoneLabel(isTargeted: isTargeted)
                }
                .buttonStyle(.plain)
              #endif
            }
            ForEach($liveUploads) { $upload in
              ShadowFileRow(title: Text(verbatim: upload.name), detail: detail(for: upload), systemImage: upload.symbol, state: upload.state) {
                action(for: $upload)
              }
            }
          }
          .shadowCard()
        }
      }
      if supportsDrop {
        StateSection("Disabled") {
          dropZone(targeted: nil).disabled(true)
        }
      }
    }
    #if os(iOS)
      .catalogAutoPresent($isImporting)
    #endif
  }

  private func dropZone(targeted: Bool?) -> some View {
    ShadowFileDropZone { _ in
      false
    } content: { isTargeted in
      zoneLabel(isTargeted: isTargeted) { isImporting = true }
    }
    .shadowPreviewDropTarget(targeted)
  }

  private func zoneLabel(isTargeted: Bool, choose: @escaping () -> Void = {}) -> some View {
    VStack(spacing: Spacing.space2) {
      Image(systemName: "square.and.arrow.down")
        .font(.title2)
        .foregroundStyle(ShadowColor.accentText)
      #if os(macOS)
        Text(isTargeted ? "Drop to add the cover" : "Drop a cover image here")
          .shadowFont(.callout)
          .foregroundStyle(isTargeted ? ShadowColor.accentText : ShadowColor.textPrimary)
          .multilineTextAlignment(.center)
        Button("Choose file…", action: choose)
          .buttonStyle(.shadowBordered)
      #else
        Text(isTargeted ? "Drop to add the cover" : "Drop a cover image here or choose a file")
          .shadowFont(.callout)
          .foregroundStyle(isTargeted ? ShadowColor.accentText : ShadowColor.textPrimary)
          .multilineTextAlignment(.center)
      #endif
      Text("PNG or JPEG, up to 10 MB")
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .contentShape(.rect)
  }

  private func detail(for upload: Upload) -> Text {
    switch upload.state {
    case .queued: Text("\(upload.size) · waiting")
    case .uploading(let progress): Text("\(upload.size) · \(progress, format: .percent.precision(.fractionLength(0)))")
    case .done: Text(upload.size)
    case .failed: Text("Too large. Choose a file under 10 MB.")
    }
  }

  @ViewBuilder
  private func action(for upload: Binding<Upload>) -> some View {
    switch upload.wrappedValue.state {
    case .uploading, .queued:
      Button("Cancel", role: .cancel) { remove(upload.wrappedValue.id) }.buttonStyle(.shadowPlain)
    case .failed:
      Button("Remove", role: .destructive) { remove(upload.wrappedValue.id) }.buttonStyle(.shadowPlain)
    case .done:
      EmptyView()
    }
  }

  private func remove(_ id: UUID) {
    uploads.removeAll { $0.id == id }
    liveUploads.removeAll { $0.id == id }
  }

  private func begin(_ name: String) {
    let upload = Upload(name: name, size: "1.2 MB", symbol: "photo", state: .uploading(progress: 0))
    liveUploads.append(upload)
    Task {
      for step in 1...10 {
        try? await Task.sleep(for: .milliseconds(250))
        guard let index = liveUploads.firstIndex(where: { $0.id == upload.id }) else { return }
        liveUploads[index].state = step == 10 ? .done : .uploading(progress: Double(step) / 10)
      }
    }
  }
}
