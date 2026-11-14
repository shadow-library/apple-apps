import SwiftUI

nonisolated public enum ShadowChartPalette {
  public static let tokens: [ShadowColorToken] = [.chart1, .chart2, .chart3, .chart4, .chart5, .chart6, .chart7, .chart8]
  public static let recommendedSeriesLimit = 4

  public static var single: Color { color(at: 0) }
  public static var colors: [Color] { tokens.map(\.color) }

  public static func token(at index: Int) -> ShadowColorToken {
    tokens.indices.contains(index) ? tokens[index] : .chartNeutral
  }

  public static func color(at index: Int) -> Color {
    token(at: index).color
  }
}

nonisolated public struct ShadowChartSeriesColors<Series: Hashable>: Sendable where Series: Sendable {
  public let series: [Series]

  public init(_ series: [Series]) {
    var seen = Set<Series>()
    self.series = series.filter { seen.insert($0).inserted }
  }

  public func index(of series: Series) -> Int? {
    self.series.firstIndex(of: series)
  }

  public func token(for series: Series) -> ShadowColorToken {
    guard let index = index(of: series) else { return .chartNeutral }
    return ShadowChartPalette.token(at: index)
  }

  public func color(for series: Series) -> Color {
    token(for: series).color
  }

  public var colors: [Color] {
    series.indices.map { ShadowChartPalette.color(at: $0) }
  }
}
