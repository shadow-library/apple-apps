import Accessibility
import Observation
import SwiftUI

@MainActor
@Observable
public final class ShadowToastCenter {
  public static let handoffDelay: Duration = .milliseconds(350)

  public private(set) var queue = ShadowToastQueue()
  @ObservationIgnored private var handoff: Task<Void, Never>?

  public init() {}

  public var current: ShadowToast? { queue.current }

  public func show(_ toast: ShadowToast) {
    queue.enqueue(toast)
  }

  public func dismiss(id: ShadowToast.ID) {
    guard queue.dismiss(id: id) else { return }
    handoff?.cancel()
    handoff = Task { [weak self] in
      try? await Task.sleep(for: Self.handoffDelay)
      guard !Task.isCancelled else { return }
      self?.queue.advance()
    }
  }

  public func dismissAll() {
    handoff?.cancel()
    queue.removeAll()
  }

  func handoffSettled() async {
    await handoff?.value
  }
}

public struct ShadowShowToastAction {
  let center: ShadowToastCenter?

  public func callAsFunction(_ toast: ShadowToast) {
    guard let center else {
      assertionFailure("shadowShowToast was called outside a shadowToastPresenter; the toast was dropped")
      return
    }
    center.show(toast)
  }

  public func dismiss(id: ShadowToast.ID) {
    center?.dismiss(id: id)
  }
}

extension EnvironmentValues {
  @Entry public var shadowShowToast = ShadowShowToastAction(center: nil)
}

extension View {
  public func shadowToastPresenter(_ center: ShadowToastCenter, placement: ShadowToastPlacement = .automatic) -> some View {
    modifier(ShadowToastPresenter(center: center, placement: placement))
  }

  public func shadowToastPresenter(placement: ShadowToastPlacement = .automatic) -> some View {
    modifier(ShadowOwnedToastPresenter(placement: placement))
  }
}

private struct ShadowOwnedToastPresenter: ViewModifier {
  let placement: ShadowToastPlacement
  @State private var center = ShadowToastCenter()

  func body(content: Content) -> some View {
    content.modifier(ShadowToastPresenter(center: center, placement: placement))
  }
}

private struct ShadowToastPresenter: ViewModifier {
  let center: ShadowToastCenter
  let placement: ShadowToastPlacement
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let edge = placement.edge(for: .current)
    let metrics = ShadowToastMetrics()
    content
      .environment(\.shadowShowToast, ShadowShowToastAction(center: center))
      .overlay(alignment: edge == .top ? .top : .bottom) {
        ZStack {
          if let toast = center.current {
            ShadowToastHost(toast: toast, edge: edge) { center.dismiss(id: toast.id) }
              .id(toast.id)
              .transition(reduceMotion ? .opacity : .move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
          }
        }
        .animation(.shadow(.emphasized, reduceMotion: reduceMotion), value: center.current?.id)
        .padding(.horizontal, metrics.edgeInset)
        .padding(edge == .top ? .top : .bottom, metrics.edgeInset)
        .modifier(ShadowToastWindowTopAnchor(isActive: edge == .top))
      }
  }
}

nonisolated enum ShadowToastAnchor {
  static func topInset(windowSafeTop: CGFloat, presenterMinY: CGFloat) -> CGFloat {
    max(windowSafeTop - presenterMinY, 0)
  }
}

private struct ShadowToastWindowTopAnchor: ViewModifier {
  let isActive: Bool

  @State private var windowSafeTop: CGFloat = 0
  @State private var presenterMinY: CGFloat = 0

  func body(content: Content) -> some View {
    #if os(iOS)
      if isActive {
        content
          .padding(.top, ShadowToastAnchor.topInset(windowSafeTop: windowSafeTop, presenterMinY: presenterMinY))
          .frame(maxHeight: .infinity, alignment: .top)
          .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }, action: { presenterMinY = $0 })
          .background { ShadowWindowSafeAreaReader(top: $windowSafeTop) }
          .ignoresSafeArea(.container, edges: .top)
      } else {
        content
      }
    #else
      content
    #endif
  }
}

#if os(iOS)
  private struct ShadowWindowSafeAreaReader: UIViewRepresentable {
    @Binding var top: CGFloat

    func makeUIView(context: Context) -> ProbeView {
      let view = ProbeView()
      view.isUserInteractionEnabled = false
      view.onChange = { top = $0 }
      return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
      var onChange: ((CGFloat) -> Void)?

      override func didMoveToWindow() {
        super.didMoveToWindow()
        report()
      }

      override func layoutSubviews() {
        super.layoutSubviews()
        report()
      }

      private func report() {
        guard let top = window?.safeAreaInsets.top, top != reported else { return }
        reported = top
        DispatchQueue.main.async { [weak self] in self?.onChange?(top) }
      }

      private var reported: CGFloat?
    }
  }
#endif

private struct ShadowToastHost: View {
  let toast: ShadowToast
  let edge: VerticalEdge
  let dismiss: () -> Void

  @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var isAccessibilityFocused: Bool
  @GestureState private var isDragging = false
  @GestureState private var dragDistance: CGFloat = 0
  @State private var releasedDistance: CGFloat = 0
  @State private var countdown: ShadowToastCountdown?

  private static let dismissDistance: CGFloat = 24
  private static let dismissVelocityDistance: CGFloat = 64
  private static let resistance: CGFloat = 0.2

  private var towardEdge: CGFloat { edge == .top ? -1 : 1 }

  private var offset: CGFloat {
    let distance = releasedDistance + dragDistance
    return (distance > 0 ? distance : distance * Self.resistance) * towardEdge
  }

  var body: some View {
    toastView
      .offset(y: offset)
      .animation(.shadow(.normal, reduceMotion: reduceMotion), value: isDragging)
      .gesture(swipe)
      .onHover { setPaused(.hover, $0) }
      .onChange(of: isDragging) { _, isDragging in setPaused(.drag, isDragging) }
      .accessibilityFocused($isAccessibilityFocused)
      .accessibilityAction(.escape, dismiss)
      .onChange(of: isAccessibilityFocused) { _, isFocused in setPaused(.accessibilityFocus, isFocused) }
      .task(id: countdown?.deadline) {
        guard let deadline = countdown?.deadline else { return }
        do {
          try await Task.sleep(until: deadline, clock: .continuous)
          dismiss()
        } catch {
          return
        }
      }
      .onAppear(perform: start)
  }

  private var toastView: some View {
    var view = ShadowToastView(toast, onDismiss: dismiss)
    view.onFocusChange = { setPaused(.focus, $0) }
    return view
  }

  private var swipe: some Gesture {
    DragGesture(minimumDistance: Spacing.space1)
      .updating($isDragging) { _, isDragging, _ in isDragging = true }
      .updating($dragDistance) { value, distance, _ in distance = value.translation.height * towardEdge }
      .onEnded { value in
        let distance = value.translation.height * towardEdge
        let predicted = value.predictedEndTranslation.height * towardEdge
        guard distance > Self.dismissDistance || predicted > Self.dismissVelocityDistance else { return }
        releasedDistance = distance
        dismiss()
      }
  }

  // A toast that is still current when its presenter comes back on screen starts a full countdown and is announced again.
  private func start() {
    countdown = toast.visibleDuration(isVoiceOverRunning: isVoiceOverRunning).map { ShadowToastCountdown(duration: $0, startingAt: .now) }
    AccessibilityNotification.Announcement(toast.announcement).post()
  }

  private func setPaused(_ reason: ShadowToastCountdown.PauseReason, _ isPaused: Bool) {
    guard var updated = countdown else { return }
    if isPaused {
      updated.pause(reason, at: .now)
    } else {
      updated.resume(reason, at: .now)
    }
    countdown = updated
  }
}
