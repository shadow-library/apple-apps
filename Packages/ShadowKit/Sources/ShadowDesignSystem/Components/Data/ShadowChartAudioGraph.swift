import Accessibility
import SwiftUI

nonisolated public enum ShadowChartAudioScale {
  public static func yRange(for series: [[Double]], stacked: Bool = false) -> ClosedRange<Double> {
    let values = stacked ? stackExtents(series) : series.flatMap { $0 }.filter(\.isFinite)
    guard let low = values.min(), let high = values.max() else { return 0...1 }
    let lower = min(low, 0)
    let upper = max(high, 0)
    return upper > lower ? lower...upper : lower...(lower + 1)
  }

  static func stackExtents(_ series: [[Double]]) -> [Double] {
    let columns = series.map(\.count).max() ?? 0
    return (0..<columns).flatMap { index -> [Double] in
      let column = series.compactMap { index < $0.count && $0[index].isFinite ? $0[index] : nil }
      return [column.filter { $0 > 0 }.reduce(0, +), column.filter { $0 < 0 }.reduce(0, +)]
    }
  }

  public static func points(categories: [String], values: [Double]) -> [(category: String, value: Double)] {
    zip(categories, values).compactMap { $0.1.isFinite ? ($0.0, $0.1) : nil }
  }
}

public struct ShadowChartAudioGraph: AXChartDescriptorRepresentable {
  public struct Series: Sendable {
    public let name: String
    public let values: [Double]
    public let isContinuous: Bool

    public init(_ name: String, values: [Double], isContinuous: Bool = false) {
      self.name = name
      self.values = values
      self.isContinuous = isContinuous
    }
  }

  private let title: String
  private let summary: String?
  private let categories: [String]
  private let xTitle: String
  private let yTitle: String
  private let series: [Series]
  private let stacked: Bool
  private let format: @Sendable (Double) -> String

  public init(
    title: String, summary: String? = nil, categories: [String], xTitle: String, yTitle: String, series: [Series], isStacked: Bool = false,
    format: @escaping @Sendable (Double) -> String = { $0.formatted() }
  ) {
    self.title = title
    self.summary = summary
    self.categories = categories
    self.xTitle = xTitle
    self.yTitle = yTitle
    self.series = series
    stacked = isStacked
    self.format = format
  }

  public func makeChartDescriptor() -> AXChartDescriptor {
    let format = format
    let xAxis = AXCategoricalDataAxisDescriptor(title: xTitle, categoryOrder: categories)
    let yAxis = AXNumericDataAxisDescriptor(
      title: yTitle, range: ShadowChartAudioScale.yRange(for: series.map(\.values), stacked: stacked), gridlinePositions: [], valueDescriptionProvider: { format($0) })
    let descriptors = series.map { series in
      AXDataSeriesDescriptor(
        name: series.name, isContinuous: series.isContinuous,
        dataPoints: ShadowChartAudioScale.points(categories: categories, values: series.values).map { AXDataPoint(x: $0.category, y: $0.value) })
    }
    return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: descriptors)
  }

  public func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
    let updated = makeChartDescriptor()
    descriptor.title = updated.title
    descriptor.summary = updated.summary
    descriptor.xAxis = updated.xAxis
    descriptor.yAxis = updated.yAxis
    descriptor.series = updated.series
  }
}

extension View {
  public func shadowAccessibilityChart(_ graph: ShadowChartAudioGraph) -> some View {
    accessibilityChartDescriptor(graph)
  }
}
