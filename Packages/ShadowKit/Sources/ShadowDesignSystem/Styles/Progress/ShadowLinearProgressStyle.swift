import SwiftUI

public struct ShadowLinearProgressStyle: ProgressViewStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    ShadowLinearProgressBody(configuration: configuration)
  }
}

extension ProgressViewStyle where Self == ShadowLinearProgressStyle {
  public static var shadowLinear: Self { Self() }
}

private struct ShadowLinearProgressBody: View {
  let configuration: ProgressViewStyleConfiguration

  @Environment(\.isEnabled) private var isEnabled

  private var fraction: Double? { configuration.fractionCompleted.map { ShadowProgress.fraction(value: $0) } }
  private var thickness: CGFloat { ShadowDensity.current == .touch ? Spacing.space1 : Spacing.space1 + 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if configuration.label != nil || configuration.currentValueLabel != nil {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
          configuration.label
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textPrimary)
          Spacer(minLength: 0)
          configuration.currentValueLabel
            .shadowFont(.footnote)
            .monospacedDigit()
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      ShadowLinearTrack(fraction: fraction, thickness: thickness)
        .accessibilityHidden(true)
    }
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
    .accessibilityElement(children: .combine)
    .modifier(ShadowProgressValue(fraction: configuration.currentValueLabel == nil ? fraction : nil))
  }
}

struct ShadowProgressValue: ViewModifier {
  let fraction: Double?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let fraction {
      content.accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0)))).accessibilityAddTraits(.updatesFrequently)
    } else {
      content.accessibilityAddTraits(.updatesFrequently)
    }
  }
}

struct ShadowLinearTrack: View {
  let fraction: Double?
  let thickness: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Capsule()
      .fill(ShadowColor.fillTrack)
      .frame(height: thickness)
      .overlay(alignment: .leading) { fill }
      .clipShape(.capsule)
      .animation(reduceMotion ? nil : .shadow(.normal), value: fraction)
  }

  @ViewBuilder
  private var fill: some View {
    if let fraction {
      GeometryReader { proxy in
        Capsule()
          .fill(ShadowProgress.isComplete(fraction) ? AnyShapeStyle(ShadowColor.successSolid) : AnyShapeStyle(.tint))
          .frame(width: proxy.size.width * fraction)
      }
    } else {
      ShadowIndeterminateFill(reduceMotion: reduceMotion)
    }
  }
}

private struct ShadowIndeterminateFill: View {
  let reduceMotion: Bool

  @State private var isActive = false

  private static let segment: CGFloat = 0.38

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width * Self.segment
      let travel = proxy.size.width - width
      Capsule()
        .fill(.tint)
        .frame(width: width)
        .offset(x: reduceMotion ? travel / 2 : (isActive ? travel : 0))
        .opacity(reduceMotion && !isActive ? 0.45 : 1)
        .animation(.easeInOut(duration: reduceMotion ? 0.8 : 0.9).repeatForever(autoreverses: true), value: isActive)
    }
    .onAppear { isActive = true }
  }
}
