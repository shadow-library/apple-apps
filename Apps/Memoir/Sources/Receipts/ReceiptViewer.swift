import CoreTransferable
import Foundation
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// memoir-web `ReceiptViewer`'s dialog: the receipt photo, zoomable, with the expense it belongs to as its subtitle, and a way to share or save it.
struct ReceiptViewer: View {
  @State private var model: ReceiptViewerModel
  @State private var zoom = ReceiptZoom()
  let subject: String
  @Environment(\.dismiss) private var dismiss

  init(model: ReceiptViewerModel, subject: String) {
    _model = State(initialValue: model)
    self.subject = subject
  }

  var body: some View {
    NavigationStack {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShadowColor.surfaceApp)
        .navigationTitle(Text("Receipt photo", tableName: "Receipts"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              dismiss()
            } label: {
              Text("Done", tableName: "Receipts")
            }
          }
          if case .shown(let shown) = model.state {
            ToolbarItemGroup(placement: .primaryAction) {
              Button {
                zoom.zoomOut()
              } label: {
                Label(title: { Text("Zoom Out", tableName: "Receipts") }, icon: { Image(systemName: "minus.magnifyingglass") })
              }
              .keyboardShortcut("-", modifiers: [.command])
              .disabled(!zoom.canZoomOut)
              Button {
                zoom.zoomIn()
              } label: {
                Label(title: { Text("Zoom In", tableName: "Receipts") }, icon: { Image(systemName: "plus.magnifyingglass") })
              }
              .keyboardShortcut("+", modifiers: [.command])
              .disabled(!zoom.canZoomIn)
              ShareLink(item: ReceiptFile(file: shown.file), preview: SharePreview(Text("Receipt photo", tableName: "Receipts"), image: Image(decorative: shown.image, scale: 1)))
            }
          }
        }
    }
    .task { await model.load() }
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case .loading:
      ProgressView { Text("Loading the receipt photo", tableName: "Receipts") }
    case .downloading:
      ProgressView { Text("Downloading the receipt photo…", tableName: "Receipts") }
    case .shown(let shown):
      ReceiptZoomableImage(image: shown.image, label: Text("Receipt for \(subject)", tableName: "Receipts"), zoom: $zoom)
    case .missing:
      unavailable(
        Text("Receipt photo not found", tableName: "Receipts"), systemImage: "photo.badge.exclamationmark",
        message: Text("This receipt photo isn’t available any more. It may have been deleted on another device, or its upload never finished.", tableName: "Receipts"))
    case .unreadable:
      unavailable(
        Text("This receipt can’t be read", tableName: "Receipts"), kind: .error,
        message: Text("It was written by a newer version of Memoir. Update the app to see it.", tableName: "Receipts"))
    case .corrupt:
      unavailable(
        Text("The receipt photo can’t be opened", tableName: "Receipts"), kind: .error,
        message: Text("Its stored copy is damaged, so it can’t be shown.", tableName: "Receipts"))
    case .syncOff:
      unavailable(
        Text("The photo isn’t on this device", tableName: "Receipts"), systemImage: "icloud.slash",
        message: Text("Sync is off here. Turn it on in Sync settings to download the photo, or open it on the device that took it.", tableName: "Receipts"))
    case .syncUnavailable:
      unavailable(
        Text("Sync can’t run right now", tableName: "Receipts"), systemImage: "exclamationmark.icloud",
        message: Text("The photo isn’t on this device, and sync can’t reach your storage at the moment. Check Sync settings, then try again.", tableName: "Receipts"))
    case .keyUnavailable:
      unavailable(
        Text("This device can’t unlock the photo", tableName: "Receipts"), systemImage: "key",
        message: Text("It was sealed with a vault key this device doesn’t have yet. Add the key in Sync settings, then try again.", tableName: "Receipts"))
    case .failed:
      unavailable(
        Text("Couldn’t load the receipt photo", tableName: "Receipts"), kind: .error,
        message: Text("The receipt photo didn’t load. Try again in a moment.", tableName: "Receipts"))
    }
  }

  private func unavailable(_ title: Text, kind: ShadowContentUnavailableKind = .empty, systemImage: String? = nil, message: Text) -> some View {
    ShadowContentUnavailable(title, kind: kind, systemImage: systemImage, message: message) {
      if model.canRetry {
        Button {
          Task { await model.load() }
        } label: {
          Text("Try Again", tableName: "Receipts")
        }
      }
    }
  }
}

nonisolated struct ReceiptZoom: Equatable {
  static let range: ClosedRange<CGFloat> = 1...6
  static let step: CGFloat = 1.5

  private(set) var scale: CGFloat = 1

  var canZoomIn: Bool { scale < Self.range.upperBound }
  var canZoomOut: Bool { scale > Self.range.lowerBound }

  mutating func set(_ scale: CGFloat) {
    self.scale = min(max(scale, Self.range.lowerBound), Self.range.upperBound)
  }

  mutating func zoomIn() { set(scale * Self.step) }

  mutating func zoomOut() { set(scale / Self.step) }

  mutating func toggle() { set(scale > 1 ? 1 : 2.5) }
}

/// Pinch, double-tap, the toolbar or VoiceOver's zoom action scale the photo inside a scroll view, so a zoomed receipt pans in both directions.
private struct ReceiptZoomableImage: View {
  let image: CGImage
  let label: Text
  @Binding var zoom: ReceiptZoom
  @GestureState private var pinch: CGFloat = 1

  var body: some View {
    GeometryReader { geometry in
      let scale = min(max(zoom.scale * pinch, ReceiptZoom.range.lowerBound), ReceiptZoom.range.upperBound)
      ScrollView([.horizontal, .vertical]) {
        Image(image, scale: 1, label: label)
          .resizable()
          .scaledToFit()
          .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
      }
      .scrollIndicators(scale > 1 ? .automatic : .hidden)
      .gesture(
        MagnifyGesture()
          .updating($pinch) { value, state, _ in state = value.magnification }
          .onEnded { value in zoom.set(zoom.scale * value.magnification) }
      )
      .onTapGesture(count: 2) { withAnimation { zoom.toggle() } }
      .accessibilityZoomAction { action in
        switch action.direction {
        case .zoomIn: zoom.zoomIn()
        case .zoomOut: zoom.zoomOut()
        }
      }
    }
  }
}

/// The photo as a file to share or save, under a name a person recognises rather than the blob's.
nonisolated struct ReceiptFile: Transferable {
  let file: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .jpeg) { receipt in SentTransferredFile(receipt.file) }
      .suggestedFileName(String(localized: "Receipt.jpg", table: "Receipts"))
  }
}
