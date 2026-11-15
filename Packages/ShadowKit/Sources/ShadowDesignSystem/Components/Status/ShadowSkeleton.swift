import SwiftUI

public struct ShadowSkeletonLine: View {
  public enum Role: Hashable, Sendable {
    case title
    case body
  }

  private let role: Role
  private let widthFraction: CGFloat

  @ScaledMetric(relativeTo: .body) private var scale = 1

  public init(_ role: Role = .body, widthFraction: CGFloat = 1) {
    self.role = role
    self.widthFraction = min(max(widthFraction, 0), 1)
  }

  public var body: some View {
    FractionalWidth(fraction: widthFraction) {
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(ShadowColor.fillTrack)
        .frame(height: (role == .title ? Spacing.space4 : Spacing.space3) * scale)
    }
    .accessibilityHidden(true)
  }
}

public struct ShadowSkeletonCircle: View {
  private let diameter: CGFloat

  public init(diameter: CGFloat = Spacing.space10) {
    self.diameter = diameter
  }

  public var body: some View {
    Circle()
      .fill(ShadowColor.fillTrack)
      .frame(width: diameter, height: diameter)
      .accessibilityHidden(true)
  }
}

public struct ShadowSkeletonRectangle: View {
  private let cornerRadius: CGFloat
  private let width: CGFloat?
  private let height: CGFloat?

  public init(cornerRadius: CGFloat = Radius.lg, width: CGFloat? = nil, height: CGFloat? = nil) {
    self.cornerRadius = cornerRadius
    self.width = width
    self.height = height
  }

  public var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(ShadowColor.fillTrack)
      .frame(width: width, height: height)
      .accessibilityHidden(true)
  }
}

private struct FractionalWidth: Layout {
  let fraction: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let width = (proposal.width ?? 0) * fraction
    return CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let subview = subviews.first else { return }
    subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width * fraction, height: bounds.height))
  }
}

private struct ShadowSkeletonModifier: ViewModifier {
  let isLoading: Bool
  let label: LocalizedStringKey?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isDimmed = false

  private var pulses: Bool { isLoading && !reduceMotion }
  private var showsLabel: Bool { isLoading && label != nil }

  func body(content: Content) -> some View {
    content
      .redacted(reason: isLoading ? .placeholder : [])
      .opacity(isDimmed ? 0.75 : 1)
      .allowsHitTesting(!isLoading)
      .accessibilityElement(children: showsLabel ? .ignore : .contain)
      .accessibilityLabel(Text(showsLabel ? label ?? "" : ""))
      .task(id: pulses) {
        guard pulses else {
          withAnimation(.easeOut(duration: ShadowMotion.fast.duration)) { isDimmed = false }
          return
        }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isDimmed = true }
      }
  }
}

private struct ShadowSkeletonShapeModifier<S: InsettableShape>: ViewModifier {
  let shape: S

  @Environment(\.redactionReasons) private var reasons

  func body(content: Content) -> some View {
    if reasons.contains(.placeholder) {
      content.hidden().overlay { shape.fill(ShadowColor.fillTrack) }
    } else {
      content
    }
  }
}

private struct ShadowRedactedTextModifier: ViewModifier {
  @Environment(\.redactionReasons) private var reasons

  func body(content: Content) -> some View {
    if reasons.contains(.placeholder) {
      content.hidden().overlay {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(ShadowColor.fillTrack)
          .scaleEffect(x: 1, y: 0.72)
      }
    } else {
      content
    }
  }
}

extension View {
  public func shadowSkeletonText() -> some View {
    modifier(ShadowRedactedTextModifier())
  }

  public func shadowSkeleton(_ isLoading: Bool, label: LocalizedStringKey? = nil) -> some View {
    modifier(ShadowSkeletonModifier(isLoading: isLoading, label: label))
  }

  public func shadowSkeletonShape(_ shape: some InsettableShape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)) -> some View {
    modifier(ShadowSkeletonShapeModifier(shape: shape))
  }
}
