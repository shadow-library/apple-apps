import Charts
import ShadowDesignSystem
import SwiftUI

private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
private let delivered: [Double] = [1_240, 1_380, 1_310, 1_520, 1_610, 980, 860]
private let opened: [Double] = [820, 910, 870, 1_030, 1_100, 610, 540]
private let outcomes = ["Delivered", "Opened"]
private let chartHeight: CGFloat = 180

private struct OutcomePoint: Identifiable {
  let day: String
  let outcome: String
  let count: Double

  var id: String { "\(day)-\(outcome)" }

  static let week: [OutcomePoint] = weekdays.indices.flatMap { index in
    [OutcomePoint(day: weekdays[index], outcome: "Delivered", count: delivered[index]), OutcomePoint(day: weekdays[index], outcome: "Opened", count: opened[index])]
  }
}

private struct DayValue: Identifiable {
  let date: Date
  let value: Double

  var id: Date { date }

  static func november(_ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day)) ?? .catalogNow
  }

  static let spend: [DayValue] = zip(1...14, [1.2, 2.9, 4.1, 6.0, 8.2, 10.1, 11.0, 13.5, 16.2, 18.9, 21.4, 24.0, 27.3, 30.1]).map { DayValue(date: november($0), value: $1) }

  static let dense: [DayValue] = (0..<90).map { offset in
    let date = Calendar.current.date(byAdding: .day, value: offset, to: november(1).addingTimeInterval(-60 * 86_400)) ?? .catalogNow
    return DayValue(date: date, value: 120 + 40 * sin(Double(offset) / 6) + 14 * sin(Double(offset) * 1.7) + Double(offset) * 0.6)
  }
}

private struct ReadingMinutes: Identifiable {
  let day: String
  let book: String
  let minutes: Double

  var id: String { "\(day)-\(book)" }

  static let books = ["The Ninth Archive", "Glass and Ash", "Salt Kings"]

  static let week: [ReadingMinutes] = weekdays.indices.flatMap { index in
    zip(books, [[34, 28, 40, 22, 30, 52, 46], [12, 20, 8, 26, 16, 24, 30], [6, 0, 14, 10, 18, 12, 4]]).map { book, minutes in
      ReadingMinutes(day: weekdays[index], book: book, minutes: minutes[index])
    }
  }
}

private struct NetChange: Identifiable {
  let day: String
  let change: Double

  var id: String { day }

  static let week = zip(weekdays, [12, 8, -3, 15, -9, -14, 6]).map { NetChange(day: $0, change: $1) }
}

private struct AppRequests: Identifiable {
  let day: String
  let app: String
  let thousands: Double

  var id: String { "\(day)-\(app)" }

  static let apps = ["Pulse", "Identity", "Synapse"]

  static let week: [AppRequests] = weekdays.indices.flatMap { index in
    zip(apps, [[8.4, 9.1, 8.8, 10.2, 11.0, 6.2, 5.8], [4.1, 4.6, 4.4, 5.0, 5.3, 3.0, 2.7], [2.0, 2.4, 3.1, 3.0, 4.2, 1.2, 0.9]]).map { app, values in
      AppRequests(day: weekdays[index], app: app, thousands: values[index])
    }
  }
}

private func count(_ value: Double) -> Text { Text(value, format: .number.precision(.fractionLength(0))) }

private struct ChartCard<Content: View, Footer: View>: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  let content: Content
  let footer: Footer

  init(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
    self.footer = footer()
  }

  var body: some View {
    ShadowCard {
      content
      footer
    } header: {
      ShadowCardHeader(title, subtitle: subtitle)
    }
  }
}

extension ChartCard where Footer == EmptyView {
  fileprivate init(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.init(title, subtitle, content: content, footer: { EmptyView() })
  }
}

private struct OutcomeBars: View {
  var selected: Binding<String?>?

  var body: some View {
    Chart {
      ForEach(OutcomePoint.week) { point in
        BarMark(x: .value("Day", point.day), y: .value("Notifications", point.count))
          .foregroundStyle(by: .value("Outcome", point.outcome))
          .position(by: .value("Outcome", point.outcome))
          .cornerRadius(Radius.sm / 2)
          .accessibilityLabel("\(point.day), \(point.outcome)")
          .accessibilityValue(count(point.count))
      }
      if let day = selected?.wrappedValue {
        ShadowChartSelectionRule(x: day) {
          ShadowChartCallout(
            title: Text(verbatim: day), value: Text("\(count(delivered[weekdays.firstIndex(of: day) ?? 0])) · \(count(opened[weekdays.firstIndex(of: day) ?? 0]))"))
        }
      }
    }
    .shadowChartStyle(series: outcomes) { count($0) }
    .chartXScale(domain: weekdays)
    .chartXSelection(value: selected ?? .constant(nil))
    .shadowAccessibilityChart(
      ShadowChartAudioGraph(
        title: "Daily notification volume", summary: "Delivered and opened notifications by weekday", categories: weekdays, xTitle: "Day", yTitle: "Notifications",
        series: [.init("Delivered", values: delivered), .init("Opened", values: opened)])
    )
    .frame(height: chartHeight)
    .padding(.top, selected == nil ? 0 : Spacing.space10 + Spacing.space2)
  }
}

private struct SpendLine: View {
  var selected: Binding<Date?>?
  var showsLatest = true

  private var selectedValue: DayValue? {
    guard let date = selected?.wrappedValue else { return nil }
    return DayValue.spend.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
  }

  var body: some View {
    Chart {
      ForEach(DayValue.spend) { point in
        LineMark(x: .value("Day", point.date), y: .value("Spend", point.value))
          .foregroundStyle(ShadowChartPalette.single)
          .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
          .accessibilityLabel(point.date.formatted(.dateTime.day().month()))
          .accessibilityValue(point.value.formatted(.currency(code: "USD")))
      }
      if let selectedValue {
        ShadowChartSelectionRule(x: selectedValue.date) {
          ShadowChartCallout(title: Text(selectedValue.date, format: .dateTime.day().month()), value: Text(selectedValue.value, format: .currency(code: "USD")))
        }
      } else if showsLatest, let last = DayValue.spend.last {
        ShadowChartLatestMark(x: last.date, y: last.value, label: Text(last.value, format: .currency(code: "USD")), color: ShadowChartPalette.single)
      }
    }
    .chartXAxis {
      AxisMarks(values: [DayValue.november(1), DayValue.november(7), DayValue.november(14)]) { value in
        AxisValueLabel(
          format: .dateTime.day().month(), anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top, collisionResolution: .disabled
        )
        .font(Font.shadow(.caption))
        .foregroundStyle(ShadowColor.textSecondary)
      }
    }
    .shadowChartStyle { Text($0, format: .currency(code: "USD").precision(.fractionLength(0))) }
    .chartXSelection(value: selected ?? .constant(nil))
    .shadowAccessibilityChart(
      ShadowChartAudioGraph(
        title: "Spend this month", summary: "Synapse spend, cumulative, 1 to 14 November", categories: DayValue.spend.map { $0.date.formatted(.dateTime.day().month()) },
        xTitle: "Day",
        yTitle: "Spend", series: [.init("Spend", values: DayValue.spend.map(\.value), isContinuous: true)], format: { $0.formatted(.currency(code: "USD")) })
    )
    .frame(height: chartHeight)
    .padding(.top, selected == nil ? 0 : Spacing.space10 + Spacing.space2)
  }
}

struct ChartPage: View {
  @State private var barSelection: String? = "Fri"
  @State private var lineSelection: Date? = DayValue.november(9)
  @State private var liveBarSelection: String?

  var body: some View {
    ComponentPage(component: .chart) {
      StateSection(
        "Grouped bars",
        note: "Series take chart-1 onward in slot order and never reorder. Gridlines are border-subtle, axis labels caption in text-secondary, the legend sits below on iPhone."
      ) {
        ChartCard("Daily notification volume", "This week, by outcome") {
          OutcomeBars()
        } footer: {
          ShadowChartLegend(outcomes)
        }
      }
      StateSection("Line with latest value", note: "The latest value is marked and labelled. Bars start at zero; lines may start where the data does.") {
        ChartCard("Spend this month", "Synapse, cumulative · budget $60") {
          SpendLine()
        } footer: {
          ShadowChartLegend(["Spend"])
        }
      }
      StateSection("Selection", note: "Touch and drag on iPhone, hover on Mac. The rule and callout are flat content, never glass.") {
        ChartCard("Spend this month", "Scrub to read a day") {
          SpendLine(selected: $lineSelection)
        }
        ChartCard("Daily notification volume", "Delivered · opened") {
          OutcomeBars(selected: $barSelection)
        }
      }
      StateSection("Area", note: "A flat fill at low opacity under the line; one series, one colour.") {
        ChartCard("Readers", "Last 90 days") {
          Chart(DayValue.dense) { point in
            AreaMark(x: .value("Day", point.date), y: .value("Readers", point.value))
              .foregroundStyle(ShadowChartPalette.single.opacity(0.18))
            LineMark(x: .value("Day", point.date), y: .value("Readers", point.value))
              .foregroundStyle(ShadowChartPalette.single)
              .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
          }
          .shadowChartStyle()
          .chartYScale(domain: 0...240)
          .shadowAccessibilityChart(
            ShadowChartAudioGraph(
              title: "Readers", summary: "Daily readers over the last 90 days, trending up", categories: DayValue.dense.map { $0.date.formatted(.dateTime.day().month()) },
              xTitle: "Day",
              yTitle: "Readers", series: [.init("Readers", values: DayValue.dense.map(\.value), isContinuous: true)])
          )
          .frame(height: chartHeight)
        }
      }
      StateSection("Stacked bars", note: "Stacks keep slot order from the bottom. Three series here; four is the most one chart should carry.") {
        ChartCard("Reading time", "Minutes per day, by book") {
          Chart(ReadingMinutes.week) { entry in
            BarMark(x: .value("Day", entry.day), y: .value("Minutes", entry.minutes))
              .foregroundStyle(by: .value("Book", entry.book))
              .accessibilityLabel("\(entry.day), \(entry.book)")
              .accessibilityValue(count(entry.minutes))
          }
          .shadowChartStyle(series: ReadingMinutes.books)
          .shadowAccessibilityChart(
            ShadowChartAudioGraph(
              title: "Reading time", summary: "Minutes read per day, stacked by book", categories: weekdays, xTitle: "Day", yTitle: "Minutes",
              series: ReadingMinutes.books.map { book in .init(book, values: ReadingMinutes.week.filter { $0.book == book }.map(\.minutes)) },
              isStacked: true)
          )
          .frame(height: chartHeight)
        } footer: {
          ShadowChartLegend(ReadingMinutes.books)
        }
      }
      StateSection(
        "Multiple series", note: "Lines share one scale and one legend. Colour is never the only cue: the legend names every series and the audio graph reads them one by one."
      ) {
        ChartCard("Requests", "Thousands per day, by app") {
          Chart(AppRequests.week) { entry in
            LineMark(x: .value("Day", entry.day), y: .value("Requests", entry.thousands))
              .foregroundStyle(by: .value("App", entry.app))
              .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
              .accessibilityLabel("\(entry.app), \(entry.day)")
              .accessibilityValue(count(entry.thousands))
          }
          .shadowChartStyle(series: AppRequests.apps)
          .shadowAccessibilityChart(
            ShadowChartAudioGraph(
              title: "Requests", summary: "Thousands of requests per day for Pulse, Identity and Synapse", categories: weekdays, xTitle: "Day", yTitle: "Thousands",
              series: AppRequests.apps.map { app in .init(app, values: AppRequests.week.filter { $0.app == app }.map(\.thousands), isContinuous: true) })
          )
          .frame(height: chartHeight)
        } footer: {
          ShadowChartLegend(AppRequests.apps)
        }
      }
      StateSection("Negative values", note: "A zero baseline in border-strong separates gains from losses; the axis includes zero.") {
        ChartCard("Net subscribers", "Gained minus lost, by day") {
          Chart {
            ForEach(NetChange.week) { entry in
              BarMark(x: .value("Day", entry.day), y: .value("Change", entry.change))
                .foregroundStyle(ShadowChartPalette.single)
                .cornerRadius(Radius.sm / 2)
                .accessibilityLabel(entry.day)
                .accessibilityValue(count(entry.change))
            }
            RuleMark(y: .value("Zero", 0))
              .foregroundStyle(ShadowColor.borderStrong)
              .lineStyle(StrokeStyle(lineWidth: 1))
              .accessibilityHidden(true)
          }
          .shadowChartStyle()
          .shadowAccessibilityChart(
            ShadowChartAudioGraph(
              title: "Net subscribers", summary: "Subscribers gained minus lost per day", categories: NetChange.week.map(\.day), xTitle: "Day", yTitle: "Change",
              series: [.init("Change", values: NetChange.week.map(\.change))])
          )
          .frame(height: chartHeight)
        }
      }
      StateSection("Dense data", note: "Ninety days thin their own labels; the line drops its markers and stays two points wide.") {
        ChartCard("Readers", "Last 90 days") {
          Chart(DayValue.dense) { point in
            LineMark(x: .value("Day", point.date), y: .value("Readers", point.value))
              .foregroundStyle(ShadowChartPalette.single)
              .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
          }
          .shadowChartStyle()
          .chartYScale(domain: 40...240)
          .frame(height: chartHeight)
          .accessibilityLabel("Readers over the last 90 days")
        }
      }
      StateSection("Sparkline", note: "A bare trend with no axes sits beside a number. It is decorative: the value next to it carries the meaning.") {
        ShadowStatisticGrid(minimumWidth: 160) {
          ShadowStatistic("Readers", value: Text("3,214"), delta: ShadowDeltaBadge(ShadowDelta(change: 12.5, fractionDigits: 1), unit: .percent), caption: Text("Last 7 days")) {
            ShadowSparkline([12, 14, 13, 18, 17, 22, 26]).tint(ShadowChartPalette.single)
          }
          ShadowStatistic("Spend", value: Text("$30.10"), caption: Text("Budget $60")) {
            ShadowSparkline(DayValue.spend.map(\.value)).tint(ShadowChartPalette.single)
          }
        }
      }
      StateSection("Loading", note: "A skeleton holds the plot area while data loads.") {
        ChartCard("Daily notification volume", "This week, by outcome") {
          ShadowSkeletonRectangle(height: chartHeight).shadowSkeleton(true, label: "Loading chart")
        }
      }
      StateSection("Empty", note: "Say what is missing instead of drawing empty axes.") {
        ChartCard("Daily notification volume", "This week, by outcome") {
          ShadowContentUnavailable("No notifications yet", systemImage: "chart.bar", message: "Volume shows up once the first message is sent.")
            .frame(maxWidth: .infinity, minHeight: chartHeight)
        }
      }
      StateSection("Light and dark") {
        SchemePair {
          VStack(alignment: .leading, spacing: Spacing.space3) {
            OutcomeBars()
            ShadowChartLegend(outcomes)
            SpendLine()
          }
        }
      }
    }
  }
}
