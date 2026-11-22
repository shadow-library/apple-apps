import AVFoundation
import ShadowDesignSystem
import SwiftUI

#if os(iOS)
  import Vision
  import VisionKit
#else
  import AppKit
#endif

/// Reads an exchange code from the camera where the device can (VisionKit's scanner on iPhone and iPad, a capture session on the Mac), and always
/// takes the code's text pasted in, for a device without a usable camera.
struct KeyCodeReader: View {
  @Environment(\.appIdentity) private var app
  let prompt: Text
  let isEnabled: Bool
  let onRead: (String) -> Void
  @State private var camera = KeyCamera.checking
  @State private var pasted = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      prompt.foregroundStyle(ShadowColor.textSecondary)
      cameraView
      pasteRow
    }
    .task { camera = await KeyCamera.check() }
  }

  @ViewBuilder
  private var cameraView: some View {
    switch camera {
    case .checking:
      ProgressView().frame(maxWidth: .infinity)
    case .available:
      KeyCodeCamera(onRead: read) { camera = .unsupported }
        .aspectRatio(4 / 3, contentMode: .fit)
        .frame(maxWidth: 420)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text("Camera view for scanning the code", tableName: "SyncKeys", bundle: .module))
    case .denied:
      #if os(macOS)
        cameraNote(
          Text(
            "Camera access is off for \(app.displayName). Turn it on in System Settings › Privacy & Security › Camera to scan, or paste the code's text below.",
            tableName: "SyncKeys", bundle: .module))
      #else
        cameraNote(Text("Camera access is off for \(app.displayName). Turn it on in Settings to scan, or paste the code's text below.", tableName: "SyncKeys", bundle: .module))
      #endif
    case .unsupported:
      cameraNote(Text("This device cannot scan codes. Paste the code's text below.", tableName: "SyncKeys", bundle: .module))
    case .noCamera:
      cameraNote(Text("This Mac has no camera. Paste the code's text below.", tableName: "SyncKeys", bundle: .module))
    }
  }

  private func cameraNote(_ text: Text) -> some View {
    Label {
      text
    } icon: {
      Image(systemName: "camera")
    }
    .shadowFont(.footnote)
    .foregroundStyle(ShadowColor.textSecondary)
  }

  private var pasteRow: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text("Or paste the code's text", tableName: "SyncKeys", bundle: .module).shadowFont(.subheadline)
      HStack(spacing: Spacing.space2) {
        TextField(text: $pasted, prompt: Text(verbatim: "SLX1:…")) { Text("Code text", tableName: "SyncKeys", bundle: .module) }
          .shadowField()
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.characters)
          #endif
          .onSubmit(usePasted)
        PasteButton(payloadType: String.self) { strings in
          Task { @MainActor in
            pasted = strings.joined()
            usePasted()
          }
        }
        .labelStyle(.iconOnly)
        Button(action: usePasted) {
          Text("Use", tableName: "SyncKeys", bundle: .module)
        }
        .buttonStyle(.shadowBordered)
        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .disabled(!isEnabled)
  }

  private func usePasted() {
    let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    pasted = ""
    read(text)
  }

  private func read(_ text: String) {
    guard isEnabled else { return }
    onRead(text)
  }
}

/// What the camera can do for the reader, asked once per appearance; access is requested only when the user has reached a scanning step.
enum KeyCamera: Equatable {
  case checking
  case available
  case denied
  case unsupported
  case noCamera

  static func check() async -> KeyCamera {
    #if os(iOS)
      guard DataScannerViewController.isSupported else { return .unsupported }
    #else
      guard AVCaptureDevice.default(for: .video) != nil else { return .noCamera }
    #endif
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: break
    case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
    default: return .denied
    }
    #if os(iOS)
      return DataScannerViewController.isAvailable ? .available : .denied
    #else
      return .available
    #endif
  }
}

/// The same code seen again within a moment is one reading, so a code held in front of the camera is reported once.
struct KeyCodeDebounce {
  static let interval: TimeInterval = 2
  private var last: (text: String, at: Date)?

  mutating func accepts(_ text: String, at now: Date = Date()) -> Bool {
    if let last, last.text == text, now.timeIntervalSince(last.at) < Self.interval { return false }
    last = (text, now)
    return true
  }
}

#if os(iOS)
  struct KeyCodeCamera: UIViewControllerRepresentable {
    let onRead: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(onRead: onRead, onUnavailable: onUnavailable)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
      let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
      scanner.delegate = context.coordinator
      return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
      context.coordinator.onRead = onRead
      guard !scanner.isScanning else { return }
      do {
        try scanner.startScanning()
      } catch {
        Task { @MainActor in onUnavailable() }
      }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
      scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
      var onRead: (String) -> Void
      private let onUnavailable: () -> Void
      private var debounce = KeyCodeDebounce()

      init(onRead: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
        self.onRead = onRead
        self.onUnavailable = onUnavailable
      }

      func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        onUnavailable()
      }

      func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for case .barcode(let barcode) in addedItems {
          guard let text = barcode.payloadStringValue, debounce.accepts(text) else { continue }
          onRead(text)
          return
        }
      }
    }
  }
#else
  struct KeyCodeCamera: NSViewRepresentable {
    let onRead: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(onRead: onRead, onUnavailable: onUnavailable)
    }

    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      view.wantsLayer = true
      let preview = AVCaptureVideoPreviewLayer(session: context.coordinator.capture.session)
      preview.videoGravity = .resizeAspectFill
      preview.frame = view.bounds
      preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      view.layer?.addSublayer(preview)
      context.coordinator.capture.start()
      return view
    }

    func updateNSView(_ view: NSView, context: Context) {
      context.coordinator.onRead = onRead
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
      coordinator.capture.stop()
    }

    final class Coordinator {
      var onRead: (String) -> Void
      private let onUnavailable: () -> Void
      private var debounce = KeyCodeDebounce()
      private(set) lazy var capture = KeyCodeCapture(onRead: { [weak self] text in self?.read(text) }, onFailure: { [weak self] in self?.onUnavailable() })

      init(onRead: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
        self.onRead = onRead
        self.onUnavailable = onUnavailable
      }

      private func read(_ text: String) {
        guard debounce.accepts(text) else { return }
        onRead(text)
      }
    }
  }

  /// A capture session that reports QR codes from the Mac's default camera.
  // AVCaptureSession is not Sendable; it is configured, started and stopped only on `queue`, which also receives the metadata.
  nonisolated final class KeyCodeCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.shadow.library.shadowappshell.key-code-capture")
    private let onRead: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable () -> Void
    private var isConfigured = false

    init(onRead: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable () -> Void) {
      self.onRead = onRead
      self.onFailure = onFailure
    }

    func start() {
      queue.async { [self] in
        if !isConfigured { isConfigured = configure() }
        guard isConfigured else {
          let onFailure = onFailure
          Task { @MainActor in onFailure() }
          return
        }
        if !session.isRunning { session.startRunning() }
      }
    }

    func stop() {
      queue.async { [self] in
        if session.isRunning { session.stopRunning() }
      }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
      for case let code as AVMetadataMachineReadableCodeObject in metadataObjects where code.type == .qr {
        guard let text = code.stringValue else { continue }
        let onRead = onRead
        Task { @MainActor in onRead(text) }
        return
      }
    }

    private func configure() -> Bool {
      guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera) else { return false }
      session.beginConfiguration()
      defer { session.commitConfiguration() }
      let output = AVCaptureMetadataOutput()
      guard session.canAddInput(input), session.canAddOutput(output) else { return false }
      session.addInput(input)
      session.addOutput(output)
      guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
      output.metadataObjectTypes = [.qr]
      output.setMetadataObjectsDelegate(self, queue: queue)
      return true
    }
  }
#endif
