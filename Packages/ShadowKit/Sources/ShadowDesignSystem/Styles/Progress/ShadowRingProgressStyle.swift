import SwiftUI

public struct ShadowRingProgressStyle: ProgressViewStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    ShadowRingProgressBody(configuration: configuration)
  }
}

extension ProgressViewStyle where Self == ShadowRingProgressStyle {
  public static var shadowRing: Self { Self() }
}

nonisolated public enum ShadowRingMetrics {
  public static func diameter(for size: ShadowControlSize) -> CGFloat {
    switch size {
    case .small: 24
    case .medium: 32
    case .large: 44
    }
  }

  public static func lineWidth(for diameter: CGFloat) -> CGFloat {
    max(diameter / 11, 2.5)
  }
}

struct ShadowRing: View {
  let fraction: Double
  let diameter: CGFloat
  var marksCompletion = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let lineWidth = ShadowRingMetrics.lineWidth(for: diameter)
    ZStack {
      Circle().stroke(ShadowColor.fillTrack, lineWidth: lineWidth)
      if fraction > 0 {
        Circle()
          .trim(from: 0, to: fraction)
          .stroke(
            marksCompletion && ShadowProgress.isComplete(fraction) ? AnyShapeStyle(ShadowColor.successSolid) : AnyShapeStyle(.tint),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      }
    }
    .padding(lineWidth / 2)
    .frame(width: diameter, height: diameter)
    .animation(reduceMotion ? nil : .shadow(.normal), value: fraction)
  }
}

private struct ShadowRingProgressBody: View {
  let configuration: ProgressViewStyleConfiguration

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @ScaledMetric(relativeTo: .body) private var scale = 1

  private var fraction: Double? { configuration.fractionCompleted.map { ShadowProgress.fraction(value: $0) } }

  var body: some View {
    let size = ShadowControlSize(controlSize)
    let diameter = ShadowRingMetrics.diameter(for: size) * scale
    HStack(spacing: Spacing.space3) {
      indicator(size: size, diameter: diameter)
        .accessibilityHidden(true)
      if configuration.label != nil || (size != .large && configuration.currentValueLabel != nil) {
        VStack(alignment: .leading, spacing: 0) {
          configuration.label
            .shadowFont(.subheadline)
            .foregroundStyle(ShadowColor.textSecondary)
          if size != .large {
            configuration.currentValueLabel
              .shadowFont(.footnote)
              .monospacedDigit()
              .foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
    }
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
    .accessibilityElement(children: .combine)
    .modifier(ShadowProgressValue(fraction: configuration.currentValueLabel == nil || size == .large ? fraction : nil))
  }

  @ViewBuilder
  private func indicator(size: ShadowControlSize, diameter: CGFloat) -> some View {
    if let fraction {
      ShadowRing(fraction: fraction, diameter: diameter)
        .overlay {
          if size == .large {
            configuration.currentValueLabel
              .font(.system(.caption2, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(ShadowColor.textPrimary)
              .minimumScaleFactor(0.7)
              .padding(ShadowRingMetrics.lineWidth(for: diameter) * 1.5)
          }
        }
    } else {
      ProgressView().progressViewStyle(.circular)
    }
  }
}
