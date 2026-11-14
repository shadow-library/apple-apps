import SwiftUI

nonisolated public enum ShadowCapacity {
  public static func fraction(value: Double, in range: ClosedRange<Double>) -> Double {
    ShadowProgress.fraction(value: value - range.lowerBound, total: range.upperBound - range.lowerBound)
  }
}

public struct ShadowCapacityGauge: View {
  private let title: Text
  private let value: Double
  private let range: ClosedRange<Double>

  public init(_ titleKey: LocalizedStringKey, value: Double, in range: ClosedRange<Double> = 0...1) {
    self.init(title: Text(titleKey), value: value, in: range)
  }

  init(title: Text, value: Double, in range: ClosedRange<Double>) {
    self.title = title
    self.value = value
    self.range = range
  }

  @Environment(\.isEnabled) private var isEnabled
  @ScaledMetric(relativeTo: .body) private var scale = 1

  private var fraction: Double { ShadowCapacity.fraction(value: value, in: range) }

  public var body: some View {
    ShadowRing(fraction: fraction, diameter: (Spacing.space10 + Spacing.space1) * scale, marksCompletion: false)
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title)
      .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
  }
}
