import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/quick-logs/weight-screen.tsx`: today's weight, the 7-day average and 90-day change, the trend and the entries.
struct WeightView: View {
  @State private var model: WeightModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: WeightModel(context: context))
  }

  var body: some View {
    @Bindable var model = model
    LogLoadable(state: model.overview.state, failureTitle: Text("Weight couldn’t be loaded", tableName: "Log")) { overview in
      ScrollView {
        ShadowAdaptiveColumns {
          VStack(alignment: .leading, spacing: Spacing.space4) {
            today(overview)
            trend(overview)
            entries(overview)
          }
          ShadowCard {
            VStack(alignment: .leading, spacing: Spacing.space2) {
              Text("Context, not a target", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
              Text(
                "Memoir never sets a goal weight and never grants or removes XP for a number on a scale. Weight is here so you can see a trend, nothing more.",
                tableName: "Log"
              )
              .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
            }
          }
        }
        .padding(Spacing.space4)
      }
    }
    .navigationTitle(Text("Weight", tableName: "Log"))
    .shadowScreen(.pushed)
    .task { await model.observe() }
    .confirmationDialog(
      Text("Replace today’s weight?", tableName: "Log"), isPresented: Binding(get: { model.replacement != nil }, set: { if !$0 { model.cancelReplacement() } }),
      titleVisibility: .visible, presenting: model.replacement
    ) { _ in
      Button {
        Task { await model.save(confirmingReplacement: true) }
      } label: {
        Text("Replace", tableName: "Log")
      }
      Button(role: .cancel) {
        model.cancelReplacement()
      } label: {
        Text("Cancel", tableName: "Log")
      }
    } message: { replacement in
      Text(
        "Today already carries \(LogFormat.weight(replacement.existing.kilograms, in: model.unit)). Saving \(LogFormat.weight(replacement.kilograms, in: model.unit)) replaces it.",
        tableName: "Log")
    }
  }

  private func today(_ overview: WeightOverview) -> some View {
    @Bindable var model = model
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text("Today", tableName: "Log").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
            Text(verbatim: overview.today.map { LogFormat.weight($0.kilograms, in: model.unit) } ?? "—")
              .shadowFont(.largeTitle).foregroundStyle(ShadowColor.textPrimary)
            Text(verbatim: todayNote(overview)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
          Spacer()
          Picker(selection: $model.unit) {
            ForEach(WeightUnit.allCases, id: \.self) { unit in Text(verbatim: LogFormat.unitSymbol(unit)).tag(unit) }
          } label: {
            Text("Unit", tableName: "Log")
          }
          .pickerStyle(.segmented)
          .fixedSize()
        }
        ShadowStatisticGrid {
          if let average = overview.sevenDayAverage.flatMap({ LogFormat.weight($0, in: model.unit) }) {
            ShadowStatistic(Text("7-day average", tableName: "Log"), value: Text(verbatim: average))
          }
          if let change = overview.ninetyDayChange {
            ShadowStatistic(Text("90 days", tableName: "Log"), value: Text(verbatim: LogFormat.weightChange(change, in: model.unit)))
          }
        }
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
          TextField(text: $model.input, prompt: Text(verbatim: LogFormat.unitSymbol(model.unit))) {
            Text("Weight in \(LogFormat.unitSymbol(model.unit))", tableName: "Log")
          }
          .shadowField()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .onSubmit { Task { await model.save() } }
          .shadowValidation(model.problem.map { Text(verbatim: $0) })
          Button {
            Task { await model.save() }
          } label: {
            Text("Save", tableName: "Log")
          }
          .buttonStyle(.shadowFilled)
          .disabled(model.isSaving || model.input.isEmpty)
        }
        Text("One value a day. Saving again replaces today’s.", tableName: "Log").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        LogSaveFeedback(failureTitle: Text("Weight not saved", tableName: "Log"), failure: model.failure, confirmation: model.confirmation)
        EntryCapNote(advisory: model.advisory)
      }
    }
  }

  private func todayNote(_ overview: WeightOverview) -> String {
    guard let today = overview.today else { return String(localized: "Nothing logged today", table: "Log") }
    let time = LogFormat.time(millis: today.loggedAtMillis, in: model.context.clock.deviceZone())
    guard let replaced = model.replaced[today.date] else { return String(localized: "Logged \(time)", table: "Log") }
    return String(localized: "Logged \(time) · replaced \(LogFormat.weight(replaced, in: model.unit))", table: "Log")
  }

  @ViewBuilder
  private func trend(_ overview: WeightOverview) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Trend", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        if overview.trend.isEmpty {
          ShadowContentUnavailable(
            Text("No trend yet", tableName: "Log"), message: Text("Weights from the last 90 days draw the trend once there is one.", tableName: "Log"))
        } else {
          let points = overview.trend.compactMap { record in
            WeightConversion.convert(record.kilograms, from: .kilograms, to: model.unit).flatMap(LogFormat.decimal).map {
              LogDayChart.Point(date: record.date, value: NSDecimalNumber(decimal: $0).doubleValue)
            }
          }
          LogDayChart(points, label: Text("Weight trend", tableName: "Log"), mark: .line, height: 150) { value in
            Text(verbatim: value.formatted(.number.precision(.fractionLength(1))))
          }
          if let lightest = overview.lightest, let heaviest = overview.heaviest {
            Text(verbatim: "\(LogFormat.weight(lightest, in: model.unit))–\(LogFormat.weight(heaviest, in: model.unit))")
              .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
    }
  }

  private func entries(_ overview: WeightOverview) -> some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Entries", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        if overview.entries.isEmpty {
          ShadowContentUnavailable(Text("No entries yet", tableName: "Log"), message: Text("Step on the scale when it suits you. Missing days are fine.", tableName: "Log"))
        }
        ForEach(overview.entries, id: \.date) { entry in
          HStack {
            Text(verbatim: LogFormat.shortDate(entry.date)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
            Spacer()
            if let replaced = model.replaced[entry.date] {
              Text("Replaced \(LogFormat.weight(replaced, in: model.unit))", tableName: "Log").shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary)
            }
            Text(verbatim: LogFormat.weight(entry.kilograms, in: model.unit)).shadowFont(.body).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }
}

#Preview {
  NavigationStack {
    if let context = try? MemoirScreenContext.inMemory() { WeightView(context: context) }
  }
}
