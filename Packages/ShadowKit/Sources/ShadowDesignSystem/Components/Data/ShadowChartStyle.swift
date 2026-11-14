import Charts
import SwiftUI

private struct ShadowChartAxesModifier: ViewModifier {
  let yLabel: ((Double) -> Text)?

  func body(content: Content) -> some View {
    content
      .chartLegend(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ShadowColor.borderSubtle)
          if let yLabel {
            AxisValueLabel {
              if let number = value.as(Double.self) ?? value.as(Int.self).map(Double.init) { yLabel(number) }
            }
            .font(Font.shadow(.caption))
            .foregroundStyle(ShadowColor.textSecondary)
          } else {
            AxisValueLabel().font(Font.shadow(.caption)).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
          AxisValueLabel().font(Font.shadow(.caption)).foregroundStyle(ShadowColor.textSecondary)
        }
      }
  }
}

private struct ShadowChartSeriesModifier<Series: Plottable & Hashable & Sendable>: ViewModifier {
  let colors: ShadowChartSeriesColors<Series>
  let yLabel: ((Double) -> Text)?

  func body(content: Content) -> some View {
    content
      .chartForegroundStyleScale(domain: colors.series, range: colors.colors)
      .modifier(ShadowChartAxesModifier(yLabel: yLabel))
  }
}

extension View {
  /// Apply after any custom `chartXAxis` or `chartYAxis`: the first axis modifier applied wins.
  public func shadowChartStyle(yLabel: ((Double) -> Text)? = nil) -> some View {
    modifier(ShadowChartAxesModifier(yLabel: yLabel))
  }

  public func shadowChartStyle<Series: Plottable & Hashable & Sendable>(series: [Series], yLabel: ((Double) -> Text)? = nil) -> some View {
    modifier(ShadowChartSeriesModifier(colors: ShadowChartSeriesColors(series), yLabel: yLabel))
  }
}

public struct ShadowChartLegend<Series: Hashable & Sendable>: View {
  private let colors: ShadowChartSeriesColors<Series>
  private let label: (Series) -> Text

  @ScaledMetric(relativeTo: .caption) private var swatch = Spacing.space3

  public init(_ series: [Series], label: @escaping (Series) -> Text) {
    colors = ShadowChartSeriesColors(series)
    self.label = label
  }

  public var body: some View {
    ShadowFlowLayout(spacing: Spacing.space4, lineSpacing: Spacing.space1) {
      ForEach(Array(colors.series.enumerated()), id: \.offset) { _, series in
        HStack(spacing: Spacing.space2) {
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(colors.color(for: series))
            .frame(width: swatch, height: swatch)
            .accessibilityHidden(true)
          label(series)
            .shadowFont(.footnote)
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }
}

extension ShadowChartLegend where Series == String {
  public init(_ series: [String]) {
    self.init(series) { Text(verbatim: $0) }
  }
}

public struct ShadowChartCallout: View {
  private let title: Text?
  private let value: Text

  public init(title: Text? = nil, value: Text) {
    self.title = title
    self.value = value
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let title {
        title
          .shadowFont(.caption)
          .foregroundStyle(ShadowColor.textSecondary)
      }
      value
        .shadowFont(.footnote)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(ShadowColor.textPrimary)
    }
    .padding(.horizontal, Spacing.space2)
    .padding(.vertical, Spacing.space1)
    .background(ShadowColor.surfaceRaised, in: .rect(cornerRadius: Radius.md, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(ShadowColor.borderDefault, lineWidth: 1) }
    .fixedSize()
  }
}

/// Emit after the data marks, or set `chartXScale(domain:)`: a categorical x value emitted earlier reorders the axis. Leave room above the plot for the callout.
public struct ShadowChartSelectionRule<X: Plottable, Callout: View>: ChartContent {
  private let x: X
  private let callout: Callout

  public init(x: X, @ViewBuilder callout: () -> Callout) {
    self.x = x
    self.callout = callout()
  }

  public var body: some ChartContent {
    RuleMark(x: .value("Selection", x))
      .foregroundStyle(ShadowColor.borderStrong)
      .lineStyle(StrokeStyle(lineWidth: 1))
      .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { callout }
      .accessibilityHidden(true)
  }
}

public struct ShadowChartLatestMark<X: Plottable, Y: Plottable>: ChartContent {
  private let x: X
  private let y: Y
  private let label: Text?
  private let color: Color

  public init(x: X, y: Y, label: Text? = nil, color: Color = ShadowChartPalette.single) {
    self.x = x
    self.y = y
    self.label = label
    self.color = color
  }

  public var body: some ChartContent {
    PointMark(x: .value("Latest", x), y: .value("Latest value", y))
      .symbolSize(40)
      .foregroundStyle(color)
      .annotation(position: .top, alignment: .trailing, spacing: Spacing.space1) {
        if let label {
          label
            .shadowFont(.caption)
            .monospacedDigit()
            .foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .accessibilityHidden(true)
  }
}
