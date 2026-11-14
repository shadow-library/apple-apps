import Foundation
import Testing

@testable import ShadowDesignSystem

@Suite("Statistic delta")
struct ShadowDeltaTests {
  private let english = Locale(identifier: "en_US")

  @Test(
    "should derive direction and sentiment from the sign and which way is good",
    arguments: [
      (0.6, true, ShadowDelta.Direction.up, ShadowDelta.Sentiment.positive),
      (-0.6, true, .down, .negative),
      (18, false, .up, .negative),
      (-18, false, .down, .positive),
      (0, true, .flat, .neutral),
      (0, false, .flat, .neutral),
    ])
  func sentiment(change: Double, higherIsBetter: Bool, direction: ShadowDelta.Direction, sentiment: ShadowDelta.Sentiment) {
    let delta = ShadowDelta(change: change, higherIsBetter: higherIsBetter)
    #expect(delta.direction == direction)
    #expect(delta.sentiment == sentiment)
  }

  @Test("should show the magnitude with the unit and the sign separately")
  func formatting() {
    let rise = ShadowDelta(change: 0.6, fractionDigits: 1)
    #expect(rise.magnitudeText(unit: .suffix("pt"), locale: english) == "0.6\u{00A0}pt")
    #expect(rise.signedText(unit: .suffix("pt"), locale: english) == "+0.6\u{00A0}pt")
    let fall = ShadowDelta(change: -18)
    #expect(fall.magnitudeText(locale: english) == "18")
    #expect(fall.signedText(locale: english) == "-18")
    #expect(ShadowDelta(change: 2.5, fractionDigits: 1).magnitudeText(unit: .percent, locale: english) == "2.5%")
  }

  @Test("should group digits and use the locale separators")
  func localized() {
    let delta = ShadowDelta(change: 1_234.5, fractionDigits: 1)
    #expect(delta.magnitudeText(locale: english) == "1,234.5")
    #expect(delta.magnitudeText(locale: Locale(identifier: "de_DE")) == "1.234,5")
  }

  @Test("should be flat when rounding removes the change, never signed zero")
  func rounding() {
    let tiny = ShadowDelta(change: 0.04, fractionDigits: 1)
    #expect(tiny.direction == .flat)
    #expect(tiny.signedText(locale: english) == "0.0")
    let negativeTiny = ShadowDelta(change: -0.04, fractionDigits: 1)
    #expect(negativeTiny.direction == .flat)
    #expect(negativeTiny.signedText(locale: english) == "0.0")
  }

  @Test("should treat non-finite changes as flat", arguments: [Double.nan, .infinity, -.infinity])
  func nonFinite(change: Double) {
    #expect(ShadowDelta(change: change).direction == .flat)
  }

  @Test("should pick the arrow from the direction")
  func arrows() {
    #expect(ShadowDelta(change: 1).systemImage == "arrow.up")
    #expect(ShadowDelta(change: -1).systemImage == "arrow.down")
    #expect(ShadowDelta(change: 0).systemImage == "equal")
  }
}

@Suite("Statistic grid")
struct ShadowStatisticGridTests {
  private let layout = ShadowStatisticGridLayout(minimumWidth: 140, spacing: 12)

  @Test(
    "should fit as many columns as the width allows without exceeding the item count",
    arguments: [(361, 4, 2), (760, 4, 4), (760, 2, 2), (100, 3, 1), (292, 4, 2), (304, 4, 2), (444, 4, 3)])
  func columns(width: Double, count: Int, expected: Int) {
    #expect(layout.columns(for: width, count: count) == expected)
  }
}

@Suite("Progress")
struct ShadowProgressTests {
  @Test("should clamp the fraction into zero through one", arguments: [(-5.0, 10.0, 0.0), (0, 10, 0), (5, 10, 0.5), (10, 10, 1), (25, 10, 1)])
  func clamps(value: Double, total: Double, expected: Double) {
    #expect(ShadowProgress.fraction(value: value, total: total) == expected)
  }

  @Test("should treat a missing total or non-finite input as no progress")
  func invalid() {
    #expect(ShadowProgress.fraction(value: 5, total: 0) == 0)
    #expect(ShadowProgress.fraction(value: 5, total: -1) == 0)
    #expect(ShadowProgress.fraction(value: .nan) == 0)
    #expect(ShadowProgress.fraction(value: .infinity) == 0)
  }

  @Test("should only be complete at a full fraction")
  func complete() {
    #expect(ShadowProgress.isComplete(1))
    #expect(!ShadowProgress.isComplete(0.99))
    #expect(!ShadowProgress.isComplete(nil))
  }

  @Test("should size rings per control size with a minimum stroke")
  func ring() {
    #expect(ShadowRingMetrics.diameter(for: .large) == 44)
    #expect(ShadowRingMetrics.lineWidth(for: 44) == 4)
    #expect(ShadowRingMetrics.lineWidth(for: 24) == 2.5)
  }
}

@Suite("Sparkline")
struct ShadowSparklineTests {
  @Test("should scale values into zero through one")
  func normalizes() {
    #expect(ShadowSparklineGeometry.normalized([10, 20, 30]) == [0, 0.5, 1])
  }

  @Test("should draw a flat series at mid height and ignore non-finite values")
  func edges() {
    #expect(ShadowSparklineGeometry.normalized([4, 4, 4]) == [0.5, 0.5, 0.5])
    #expect(ShadowSparklineGeometry.normalized([1, .nan, 3]) == [0, 1])
    #expect(ShadowSparklineGeometry.normalized([]).isEmpty)
  }
}

@Suite("Capacity")
struct ShadowCapacityTests {
  @Test(
    "should map a value inside its range to a fraction",
    arguments: [(41.2, 0.0, 60.0, 0.6866666666666666), (0, 0, 60, 0), (60, 0, 60, 1), (90, 0, 60, 1), (-5, 0, 60, 0), (15, 10, 20, 0.5), (3, 3, 3, 0)])
  func fraction(value: Double, lower: Double, upper: Double, expected: Double) {
    #expect(abs(ShadowCapacity.fraction(value: value, in: lower...upper) - expected) < 0.000_001)
  }
}
