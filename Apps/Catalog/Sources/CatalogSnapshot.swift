#if os(macOS)
  import AppKit
  import SwiftUI

  enum CatalogSnapshotError: Error, CustomStringConvertible {
    case captureUnavailable
    case captureFailed(windowNumber: Int)
    case encodingFailed
    case writeFailed(URL, underlying: any Error)

    var description: String {
      switch self {
      case .captureUnavailable: "CGWindowListCreateImage is not available on this system"
      case .captureFailed(let windowNumber): "could not capture window \(windowNumber)"
      case .encodingFailed: "could not encode the capture as PNG"
      case .writeFailed(let url, let underlying): "could not write \(url.path): \(underlying.localizedDescription)"
      }
    }
  }

  enum CatalogSnapshot {
    private static let windowSize = CGSize(width: 1280, height: 820)
    private static let settleDelay = Duration.milliseconds(400)
    private static let pollInterval = Duration.milliseconds(250)
    private static let maximumPolls = 12

    // CGWindowListCreateImage is obsoleted in the SDK, but unlike ScreenCaptureKit it still captures the process's own windows
    // (glass included) without Screen Recording permission, so it is looked up at runtime.
    private typealias CreateWindowImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
    private static let createWindowImage: CreateWindowImage? = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage").map {
      unsafeBitCast($0, to: CreateWindowImage.self)
    }

    static func capture(_ window: NSWindow, to url: URL) async -> Never {
      place(window)
      do throws(CatalogSnapshotError) {
        let (image, isStable) = try await stableImage(of: window)
        if !isStable { report("page did not settle after \(maximumPolls) polls; captured the last frame") }
        try write(image, to: url)
        exit(EXIT_SUCCESS)
      } catch {
        report(error.description)
        exit(EXIT_FAILURE)
      }
    }

    private static func place(_ window: NSWindow) {
      let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
      let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: windowSize)
      let mouse = NSEvent.mouseLocation
      let origins = [
        CGPoint(x: visible.midX - windowSize.width / 2, y: visible.midY - windowSize.height / 2),
        CGPoint(x: visible.minX, y: visible.maxY - windowSize.height),
        CGPoint(x: visible.maxX - windowSize.width, y: visible.maxY - windowSize.height),
        CGPoint(x: visible.minX, y: visible.minY),
        CGPoint(x: visible.maxX - windowSize.width, y: visible.minY),
      ]
      let origin = origins.first { !CGRect(origin: $0, size: windowSize).contains(mouse) } ?? origins[0]
      window.isRestorable = false
      window.setFrame(CGRect(origin: origin, size: windowSize), display: true)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate()
    }

    private static func stableImage(of window: NSWindow) async throws(CatalogSnapshotError) -> (CGImage, Bool) {
      try? await Task.sleep(for: settleDelay)
      var previous = try image(of: window)
      for _ in 0..<maximumPolls {
        try? await Task.sleep(for: pollInterval)
        let current = try image(of: window)
        if current.dataProvider?.data == previous.dataProvider?.data { return (current, true) }
        previous = current
      }
      return (previous, false)
    }

    private static func image(of window: NSWindow) throws(CatalogSnapshotError) -> CGImage {
      guard let createWindowImage else { throw .captureUnavailable }
      let windowID = CGWindowID(window.windowNumber)
      guard let image = createWindowImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else {
        throw .captureFailed(windowNumber: window.windowNumber)
      }
      return image.takeRetainedValue()
    }

    private static func write(_ image: CGImage, to url: URL) throws(CatalogSnapshotError) {
      guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw .encodingFailed }
      do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
      } catch {
        throw .writeFailed(url, underlying: error)
      }
    }

    private static func report(_ message: String) {
      FileHandle.standardError.write(Data("catalog-snapshot: \(message)\n".utf8))
    }
  }

  private struct SnapshotWindowReader: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WindowObservingView {
      WindowObservingView { window in
        Task { await CatalogSnapshot.capture(window, to: url) }
      }
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {}
  }

  private final class WindowObservingView: NSView {
    private let onWindow: (NSWindow) -> Void
    private var hasFired = false

    init(onWindow: @escaping (NSWindow) -> Void) {
      self.onWindow = onWindow
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, !hasFired else { return }
      hasFired = true
      onWindow(window)
    }
  }

  extension View {
    @ViewBuilder
    func catalogSnapshot(to url: URL?) -> some View {
      if let url {
        background(SnapshotWindowReader(url: url))
      } else {
        self
      }
    }
  }
#endif
