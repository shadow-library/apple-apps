import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import VisionKit
#endif

/// The ways to add a receipt photo: the document camera where the device has one, the photo library, and a file.
struct ReceiptPickers: View {
  let draft: ReceiptDraft
  @State private var libraryItem: PhotosPickerItem?
  @State private var isImporting = false
  @State private var isScanning = false

  var body: some View {
    Group {
      if ReceiptScanner.isAvailable {
        Button {
          isScanning = true
        } label: {
          Label(title: { Text("Scan Receipt", tableName: "Receipts") }, icon: { Image(systemName: "doc.viewfinder") })
        }
      }
      PhotosPicker(selection: $libraryItem, matching: .images, photoLibrary: .shared()) {
        Label(title: { Text("Choose Photo", tableName: "Receipts") }, icon: { Image(systemName: "photo.on.rectangle") })
      }
      Button {
        isImporting = true
      } label: {
        Label(title: { Text("Choose File", tableName: "Receipts") }, icon: { Image(systemName: "folder") })
      }
    }
    .onChange(of: libraryItem) { _, item in
      guard let item else { return }
      libraryItem = nil
      Task { await loadLibraryItem(item) }
    }
    .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
      guard case .success(let url) = result else { return }
      Task { await loadFile(url) }
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $isScanning) {
        ReceiptScanner { data in
          isScanning = false
          guard let data else { return }
          Task { await draft.take(data) }
        }
        .ignoresSafeArea()
      }
    #endif
  }

  private func loadLibraryItem(_ item: PhotosPickerItem) async {
    let pick = draft.startPick()
    guard let data = try? await item.loadTransferable(type: Data.self) else { return draft.refuse(.unreadable, pick: pick) }
    await draft.take(data, pick: pick)
  }

  /// A file picked outside the sandbox is readable only while its security scope is held.
  private func loadFile(_ url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let pick = draft.startPick()
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > ReceiptPhoto.maximumSourceBytes { return draft.refuse(.tooLarge, pick: pick) }
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return draft.refuse(.unreadable, pick: pick) }
    await draft.take(data, pick: pick)
  }
}

#if os(iOS)
  /// VisionKit's document camera, which finds the receipt's edges and flattens it; the first page is the receipt.
  struct ReceiptScanner: UIViewControllerRepresentable {
    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    let finish: (Data?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
      let controller = VNDocumentCameraViewController()
      controller.delegate = context.coordinator
      return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
      let finish: (Data?) -> Void

      init(finish: @escaping (Data?) -> Void) {
        self.finish = finish
      }

      func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        finish(scan.pageCount > 0 ? scan.imageOfPage(at: 0).jpegData(compressionQuality: 0.9) : nil)
      }

      func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        finish(nil)
      }

      func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
        finish(nil)
      }
    }
  }
#else
  enum ReceiptScanner {
    static let isAvailable = false
  }
#endif
