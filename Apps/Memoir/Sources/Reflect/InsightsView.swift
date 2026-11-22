import Charts
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// `features/insights/index.tsx`: the owner's history against itself, with no leaderboards and no comparison with anyone else.
struct InsightsView: View {
  @State private var model: InsightsModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: InsightsModel(context: context))
  }

  var body: some View {
    InsightsScreen(model: model)
  }
}

private struct InsightsScreen: View {
  @Bindable var model: InsightsModel
  @State private var generation = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Text("Your history against itself. There are no leaderboards, no percentile ranks and no comparison with anyone else.", tableName: "Reflect")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        Picker(selection: $model.period) {
          Text("30 days", tableName: "Reflect").tag(InsightPeriod.thirtyDays)
          Text("90 days", tableName: "Reflect").tag(InsightPeriod.ninetyDays)
          Text("Year", tableName: "Reflect").tag(InsightPeriod.year)
        } label: {
          Text("Period", tableName: "Reflect")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(verbatim: InsightsPresentation.periodNote(model.period))
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
        content
      }
      .padding(Spacing.space4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(ShadowColor.surfaceApp)
    .navigationTitle(Text(MemoirDestination.insights.title))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        NavigationLink(value: MemoirRoute.destination(.ask)) {
          Label {
            Text("Ask the coach about this", tableName: "Reflect")
          } icon: {
            Image(systemName: MemoirDestination.ask.systemImage)
          }
        }
        .shadowBarItem()
      }
    }
    .shadowScreen(.root)
    .task { await model.followToday() }
    .task { await model.observeLookups() }
    .task(id: ObservationKey(read: model.readKey, generation: generation)) { await model.observe() }
  }

  @ViewBuilder
  private var content: some View {
    if let failure = model.day.failure {
      ShadowContentUnavailable(Text("Insights couldn’t be loaded", tableName: "Reflect"), kind: .error, message: failure.text)
    } else if case .failed(let error) = model.statistics.state {
      ShadowContentUnavailable(Text("Couldn’t load this right now", tableName: "Reflect"), kind: .error, message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try again", tableName: "Reflect")
        }
        .buttonStyle(.shadowBordered)
      }
    } else if let statistics = model.shown {
      InsightsContent(statistics: statistics, lookups: model.lookups.state.value, bodyClasses: model.bodyClasses)
    } else {
      ProgressView().frame(maxWidth: .infinity)
    }
  }

  private struct ObservationKey: Hashable {
    let read: InsightsReadKey?
    let generation: Int
  }
}

private struct InsightsContent: View {
  let statistics: InsightStatistics
  let lookups: ReflectLookups?
  let bodyClasses: Set<SyncClass>

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowStatisticGrid(minimumWidth: 160) {
        ForEach(InsightsPresentation.kpis(statistics, streak: lookups?.longestStreak)) { kpi in
          InsightTile(kpi: kpi)
        }
      }
      ShadowAdaptiveColumns {
        byQuest
        byWeekday
        byMonth
        reasons
        spending
        bodyAndHealth
        InsightCard(title: Text("These numbers are yours alone", tableName: "Reflect")) {
          Text(
            "Every comparison here is you against your own history, and every one of them is optional to look at. Nothing on this screen is shared, published or ranked.",
            tableName: "Reflect"
          )
          .insightNote()
        }
        .shadowColumnSpan(.full)
      }
    }
  }

  private var byQuest: some View {
    let bars = InsightsPresentation.byQuest(statistics)
    return InsightCard(title: Text("Adherence by quest", tableName: "Reflect")) {
      Text("Share of scheduled occurrences kept. Partials count as half.", tableName: "Reflect").insightNote()
      if bars.isEmpty {
        Text("No quests logged in this period yet.", tableName: "Reflect").insightNote()
      } else {
        InsightMeters(bars: bars, maximum: 100)
      }
    }
  }

  private var byWeekday: some View {
    let bars = InsightsPresentation.byWeekday(statistics)
    return InsightCard(title: Text("Adherence by weekday", tableName: "Reflect")) {
      Text(verbatim: InsightsPresentation.weekdayNote(statistics)).insightNote()
      if bars.contains(where: \.hasEntries) {
        InsightColumns(
          bars: bars, title: String(localized: "Adherence by weekday", table: "Reflect"), xTitle: String(localized: "Weekday", table: "Reflect"),
          axis: String(localized: "Kept", table: "Reflect"))
      }
    }
  }

  private var byMonth: some View {
    let bars = InsightsPresentation.byMonth(statistics)
    return InsightCard(title: Text("Experience earned, by month", tableName: "Reflect")) {
      if bars.contains(where: \.hasEntries) {
        InsightColumns(
          bars: bars, title: String(localized: "Experience earned, by month", table: "Reflect"), xTitle: String(localized: "Month", table: "Reflect"),
          axis: String(localized: "XP", table: "Reflect"))
      }
      Text(verbatim: InsightsPresentation.monthNote(statistics)).insightNote()
    }
  }

  private var reasons: some View {
    let bars = InsightsPresentation.reasons(statistics)
    return InsightCard(title: Text("Reasons given on missed and partial days", tableName: "Reflect")) {
      InsightMeters(bars: bars, maximum: max(1, bars.map(\.value).max() ?? 1))
      Text(verbatim: InsightsPresentation.reasonsNote(statistics)).insightNote()
    }
  }

  private var spending: some View {
    let bars = InsightsPresentation.spending(statistics, lookups: lookups)
    return InsightCard(title: Text("Spending by category", tableName: "Reflect")) {
      InsightMeters(bars: bars, maximum: max(1, bars.map(\.value).max() ?? 1))
      Text(verbatim: InsightsPresentation.spendingNote(statistics, lookups: lookups)).insightNote()
      if let pending = statistics.spent.flatMap({ ReflectCopy.pending($0.pending) }) {
        Text(verbatim: pending).insightNote()
      }
    }
  }

  private var bodyAndHealth: some View {
    InsightCard(title: Text("Body and health", tableName: "Reflect")) {
      if statistics.body.isEmpty {
        Text("Not enough weight or health entries yet to show a trend.", tableName: "Reflect").insightNote()
      } else {
        ForEach(statistics.body, id: \.subject) { series in
          InsightTrend(series: series)
        }
      }
      ForEach(ReflectCopy.missingClasses(bodyClasses), id: \.self) { note in
        Text(verbatim: note).insightNote()
      }
      Text(verbatim: ReflectCopy.bodyOnThisDevice).insightNote()
    }
  }
}

private struct InsightTile: View {
  let kpi: InsightKPI

  var body: some View {
    ShadowStatistic(
      Text(verbatim: kpi.label), value: Text(verbatim: kpi.value ?? "—"),
      delta: kpi.deltaPercent.map { ShadowDeltaBadge(ShadowDelta(change: $0, higherIsBetter: kpi.higherIsBetter), unit: .percent) },
      caption: Text(verbatim: kpi.caption)
    )
    .shadowCard()
  }
}

struct InsightCard<Content: View>: View {
  let title: Text
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      title
        .shadowFont(.headline)
        .foregroundStyle(ShadowColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      content
    }
    .shadowCard()
  }
}

extension View {
  fileprivate func insightNote() -> some View {
    shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).fixedSize(horizontal: false, vertical: true)
  }
}

/// The reference's meters: a labelled track per bar, filled to its share of `maximum`.
private struct InsightMeters: View {
  let bars: [InsightBar]
  let maximum: Double

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      ForEach(bars) { bar in
        VStack(alignment: .leading, spacing: Spacing.space1) {
          HStack(alignment: .firstTextBaseline) {
            Text(verbatim: bar.label).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
            Spacer(minLength: Spacing.space2)
            Text(verbatim: bar.caption).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
          }
          ProgressView(value: min(max(bar.value / maximum, 0), 1)).progressViewStyle(.shadowLinear)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: bar.accessibilityLabel))
      }
    }
  }
}

/// A column chart with an audio graph and every column read by VoiceOver as the reference's labels say.
private struct InsightColumns: View {
  let bars: [InsightBar]
  let title: String
  let xTitle: String
  let axis: String

  var body: some View {
    Chart(bars) { bar in
      BarMark(x: .value(xTitle, bar.label), y: .value(axis, bar.value))
        .foregroundStyle(bar.hasEntries ? ShadowChartPalette.single : ShadowColor.chartNeutral)
        .cornerRadius(Radius.sm / 2)
        .accessibilityLabel(Text(verbatim: bar.accessibilityLabel))
        .accessibilityValue(Text(verbatim: bar.caption))
    }
    .chartXScale(domain: bars.map(\.label))
    .shadowChartStyle()
    .frame(height: 160)
    .shadowAccessibilityChart(
      ShadowChartAudioGraph(
        title: title, summary: bars.map(\.accessibilityLabel).joined(separator: ", "), categories: bars.map(\.label), xTitle: xTitle, yTitle: axis,
        series: [.init(title, values: bars.map(\.value))]))
  }
}

/// `Trend` (`features/insights/index.tsx:226-243`): a series' name and reading over a line of its days.
private struct InsightTrend: View {
  let series: BodySeries

  private var points: [(date: Date, value: Double)] {
    series.points.compactMap { point in
      point.value.flatMap(ReflectFormat.double).map { (Date(timeIntervalSince1970: TimeInterval(point.date.daysSinceEpoch) * 86_400), $0) }
    }
  }

  var body: some View {
    let name = ReflectCopy.subjectName(series.subject)
    let reading = InsightsPresentation.trendValue(series)
    VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: name).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        Spacer(minLength: Spacing.space2)
        Text(verbatim: reading).shadowFont(.subheadline).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
      }
      Chart(points, id: \.date) { point in
        LineMark(x: .value(String(localized: "Day", table: "Reflect"), point.date), y: .value(name, point.value))
          .foregroundStyle(ShadowChartPalette.single)
          .interpolationMethod(.monotone)
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartYScale(domain: .automatic(includesZero: false))
      .frame(height: 48)
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("\(name) over the period: \(reading)", tableName: "Reflect"))
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      InsightsView(context: context)
    }
  }
}
