import Testing

@testable import ShadowDesignSystem

@Suite("Chart palette")
struct ShadowChartPaletteTests {
  @Test("should list chart-1 to chart-8 in slot order")
  func order() {
    #expect(ShadowChartPalette.tokens == [.chart1, .chart2, .chart3, .chart4, .chart5, .chart6, .chart7, .chart8])
  }

  @Test("should give every slot a distinct light and dark colour")
  func distinct() {
    let light = Set(ShadowChartPalette.tokens.map { String(describing: $0.light) })
    let dark = Set(ShadowChartPalette.tokens.map { String(describing: $0.dark) })
    #expect(light.count == 8)
    #expect(dark.count == 8)
  }

  @Test("should use chart-1 for single series")
  func single() {
    #expect(ShadowChartPalette.token(at: 0) == .chart1)
  }

  @Test("should fall back to the neutral slot past eight series")
  func overflow() {
    #expect(ShadowChartPalette.token(at: 7) == .chart8)
    #expect(ShadowChartPalette.token(at: 8) == .chartNeutral)
    #expect(ShadowChartPalette.token(at: -1) == .chartNeutral)
  }

  @Test("should assign colours by the order series are declared")
  func seriesMapping() {
    let colors = ShadowChartSeriesColors(["Delivered", "Failed", "Opened"])
    #expect(colors.token(for: "Delivered") == .chart1)
    #expect(colors.token(for: "Failed") == .chart2)
    #expect(colors.token(for: "Opened") == .chart3)
    #expect(colors.token(for: "Unknown") == .chartNeutral)
  }

  @Test("should be deterministic and ignore duplicates")
  func deterministic() {
    let first = ShadowChartSeriesColors(["a", "b", "a", "c", "b"])
    let second = ShadowChartSeriesColors(["a", "b", "a", "c", "b"])
    #expect(first.series == ["a", "b", "c"])
    #expect(first.series == second.series)
    #expect(first.token(for: "c") == .chart3)
    #expect(first.index(of: "c") == second.index(of: "c"))
  }

  @Test("should keep a series colour when data order changes")
  func independentOfDataOrder() {
    let declared = ShadowChartSeriesColors(["Delivered", "Opened"])
    let shuffled = ["Opened", "Delivered", "Opened"]
    #expect(shuffled.map { declared.token(for: $0) } == [.chart2, .chart1, .chart2])
  }
}

@Suite("Chart audio graph")
struct ShadowChartAudioScaleTests {
  @Test("should always include zero in the value range")
  func includesZero() {
    #expect(ShadowChartAudioScale.yRange(for: [[3, 5], [4]]) == 0...5)
    #expect(ShadowChartAudioScale.yRange(for: [[-4, -1]]) == -4...0)
    #expect(ShadowChartAudioScale.yRange(for: [[-2, 6]]) == -2...6)
  }

  @Test("should cover stack totals when stacked")
  func stacked() {
    #expect(ShadowChartAudioScale.yRange(for: [[3, 4], [2, 5], [1, 1]], stacked: true) == 0...10)
    #expect(ShadowChartAudioScale.yRange(for: [[3, 4], [2, 5], [1, 1]]) == 0...5)
    #expect(ShadowChartAudioScale.yRange(for: [[3, -2], [2, -3]], stacked: true) == -5...5)
  }

  @Test("should give empty or flat data a usable range")
  func degenerate() {
    #expect(ShadowChartAudioScale.yRange(for: []) == 0...1)
    #expect(ShadowChartAudioScale.yRange(for: [[]]) == 0...1)
    #expect(ShadowChartAudioScale.yRange(for: [[0, 0]]) == 0...1)
    #expect(ShadowChartAudioScale.yRange(for: [[.nan, .infinity]]) == 0...1)
  }

  @Test("should pair categories with values and drop non-finite values")
  func points() {
    let result = ShadowChartAudioScale.points(categories: ["Mon", "Tue", "Wed"], values: [1, .nan, 3, 4])
    #expect(result.map(\.category) == ["Mon", "Wed"])
    #expect(result.map(\.value) == [1, 3])
  }
}
