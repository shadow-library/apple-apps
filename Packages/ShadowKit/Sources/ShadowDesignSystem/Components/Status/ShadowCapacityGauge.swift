import SwiftUI

nonisolated public enum ShadowCapacity {
  static let nearLimit = 0.9

  public static func fraction(value: Double, in range: ClosedRange<Double>) -> Double {
    ShadowProgress.fraction(value: value - range.lowerBound, total: range.upperBound - range.lowerBound)
  }
}

nonisolated enum ShadowCapacityLevel: Hashable, Sendable, CaseIterable {
  case normal
  case nearLimit
  case atLimit

  init(fraction: Double) {
    if fraction >= 1 {
      self = .atLimit
    } else if fraction >= ShadowCapacity.nearLimit {
      self = .nearLimit
    } else {
      self = .normal
    }
  }

  var tint: Color {
    switch self {
    case .normal: ShadowColor.accent
    case .nearLimit: ShadowColor.warningSolid
    case .atLimit: ShadowColor.dangerSolid
    }
  }
}

public struct ShadowCapacityGauge: View {
  private let title: Text
  private let value: Double
  private let range: ClosedRange<Double>
  private let showsTitle: Bool

  public init(_ titleKey: LocalizedStringKey, value: Double, in range: ClosedRange<Double> = 0...1) {
    self.init(title: Text(titleKey), value: value, in: range, showsTitle: true)
  }

  init(title: Text, value: Double, in range: ClosedRange<Double>, showsTitle: Bool) {
    self.title = title
    self.value = value
    self.range = range
    self.showsTitle = showsTitle
  }

  @Environment(\.isEnabled) private var isEnabled
  @ScaledMetric(relativeTo: .body) private var scale = 1

  private var fraction: Double { ShadowCapacity.fraction(value: value, in: range) }

  public var body: some View {
    let fraction = fraction
    let level = ShadowCapacityLevel(fraction: fraction)
    let diameter = (Spacing.space10 + Spacing.space1) * scale
    VStack(spacing: Spacing.space1) {
      ShadowRing(fraction: fraction, diameter: diameter, marksCompletion: false)
        .tint(level.tint)
        .overlay { centre(level: level, fraction: fraction, diameter: diameter) }
      if showsTitle {
        title
          .shadowFont(.caption)
          .foregroundStyle(ShadowColor.textSecondary)
          .lineLimit(1)
      }
    }
    .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
  }

  @ViewBuilder
  private func centre(level: ShadowCapacityLevel, fraction: Double, diameter: CGFloat) -> some View {
    if level == .atLimit {
      Image(systemName: "exclamationmark")
        .font(.system(.footnote, weight: .bold))
        .foregroundStyle(ShadowColor.dangerText)
    } else {
      Text(fraction, format: .percent.precision(.fractionLength(0)))
        .font(.system(.caption2, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(ShadowColor.textPrimary)
        .minimumScaleFactor(0.7)
        .lineLimit(1)
        .padding(ShadowRingMetrics.lineWidth(for: diameter) * 1.5)
    }
  }
}
