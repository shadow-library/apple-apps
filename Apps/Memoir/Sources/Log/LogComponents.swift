import Charts
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// One quiet line under a form (`EntryCapNote`): the allowance is advisory, so nothing here blocks a save.
struct EntryCapNote: View {
  let advisory: EntryCapAdvisory?

  var body: some View {
    if let note = LogFormat.capNote(advisory) {
      Text(verbatim: note).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

/// What a save said: the failure in the reference's words, or a short confirmation.
struct LogSaveFeedback: View {
  let failureTitle: Text
  let failure: PresentedError?
  let confirmation: String?

  var body: some View {
    if let failure {
      ShadowCallout(failureTitle, message: failure.text, intent: .danger)
    } else if let confirmation {
      Text(verbatim: confirmation).shadowFont(.footnote).foregroundStyle(ShadowColor.successText).accessibilityAddTraits(.updatesFrequently)
    }
  }
}

/// A day per mark over a trailing window (`SparkBars`): a day with nothing logged has no mark, which is not a zero. A line reads a range (`domain="range"`)
/// rather than counting from zero.
struct LogDayChart: View {
  enum Mark {
    case bars
    case line
  }

  struct Point: Identifiable {
    let date: LocalDate
    let value: Double

    var id: LocalDate { date }
  }

  let points: [Point]
  let label: Text
  let mark: Mark
  let height: CGFloat
  let valueText: (Double) -> Text

  init(_ points: [Point], label: Text, mark: Mark = .bars, height: CGFloat = 96, valueText: @escaping (Double) -> Text) {
    self.points = points
    self.label = label
    self.mark = mark
    self.height = height
    self.valueText = valueText
  }

  var body: some View {
    Chart(points) { point in
      let x = PlottableValue.value(Text("Day", tableName: "Log"), LogFormat.midnight(of: point.date), unit: .day)
      let y = PlottableValue.value(label, point.value)
      switch mark {
      case .bars:
        BarMark(x: x, y: y)
          .cornerRadius(Radius.sm / 2)
          .accessibilityLabel(Text(verbatim: LogFormat.shortDate(point.date)))
          .accessibilityValue(valueText(point.value))
      case .line:
        LineMark(x: x, y: y)
          .interpolationMethod(.monotone)
          .symbol(.circle)
          .accessibilityLabel(Text(verbatim: LogFormat.shortDate(point.date)))
          .accessibilityValue(valueText(point.value))
      }
    }
    .chartYScale(domain: .automatic(includesZero: mark == .bars))
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 3)) { _ in
        AxisValueLabel(format: Date.FormatStyle(timeZone: LogFormat.utc).day().month(.abbreviated)).font(Font.shadow(.caption))
      }
    }
    .shadowChartStyle(yLabel: valueText)
    .frame(height: height)
    .accessibilityLabel(label)
  }
}

extension LogDayChart.Point {
  static func points<Value>(_ days: [DayValue<Value>], _ value: (Value) -> Double?) -> [LogDayChart.Point] {
    days.compactMap { day in day.value.flatMap(value).map { LogDayChart.Point(date: day.date, value: $0) } }
  }
}

/// A loaded read, its spinner, or the reason it could not be read.
struct LogLoadable<Value: Sendable & Equatable, Content: View>: View {
  let state: Loadable<Value>
  let failureTitle: Text
  @ViewBuilder let content: (Value) -> Content

  var body: some View {
    switch state {
    case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error): ShadowContentUnavailable(failureTitle, kind: .error, message: error.text)
    case .loaded(let value): content(value)
    }
  }
}
