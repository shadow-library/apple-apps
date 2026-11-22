import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// `features/quick-logs/health-screen.tsx`: the quests a metric's day can complete, each metric's day and last 14 days, Apple Health, and the owner's own
/// metrics.
struct BodyAndHealthView: View {
  @State private var model: BodyAndHealthModel
  @State private var editing: MetricEditing?

  init(context: MemoirScreenContext) {
    _model = State(initialValue: BodyAndHealthModel(context: context))
  }

  var body: some View {
    LogLoadable(state: model.overview.state, failureTitle: Text("Metrics couldn’t be loaded", tableName: "Log")) { overview in
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          offers(overview)
          ShadowAdaptiveColumns {
            VStack(alignment: .leading, spacing: Spacing.space4) {
              ForEach(overview.series, id: \.metric.reference) { series in card(series, overview: overview) }
            }
            VStack(alignment: .leading, spacing: Spacing.space4) {
              HealthSection(model: model.health)
              ShadowCard {
                VStack(alignment: .leading, spacing: Spacing.space2) {
                  Text("All of this is optional", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
                  Text(
                    "Blank days are blank — they are not zeros, they do not break a streak, and they never cost HP. Only quests with an explicit threshold read these numbers.",
                    tableName: "Log"
                  )
                  .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
                }
              }
            }
          }
          LogSaveFeedback(failureTitle: Text("Not saved", tableName: "Log"), failure: model.failure, confirmation: model.confirmation)
        }
        .padding(Spacing.space4)
      }
    }
    .navigationTitle(Text("Body & health", tableName: "Log"))
    .shadowScreen(.pushed)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          editing = MetricEditing(metric: nil)
        } label: {
          Label {
            Text("New metric", tableName: "Log")
          } icon: {
            Image(systemName: "plus")
          }
        }
      }
    }
    .task { await model.observe() }
    .sheet(item: $editing) { editing in MetricFormSheet(model: model, metric: editing.metric) }
  }

  @ViewBuilder
  private func offers(_ overview: MetricsOverview) -> some View {
    ForEach(overview.offers, id: \.self) { offer in
      if let metric = overview.series.first(where: { $0.metric.reference == offer.metric })?.metric {
        let occurrence = Occurrence(quest: offer.quest, date: offer.date)
        ShadowCallout(
          Text("\(MetricFormat.value(offer.thresholdValue, of: metric)) reached — “\(offer.questName)” can be completed", tableName: "Log"),
          message: Text(
            "You logged \(MetricFormat.value(offer.currentValue, of: metric)). The quest is yours to complete: Memoir never completes a quest for you, even when the threshold is met.",
            tableName: "Log"),
          intent: .success
        ) {
          Button {
            Task { await model.complete(offer) }
          } label: {
            Text("Complete the quest", tableName: "Log")
          }
          .buttonStyle(.shadowFilled)
          .disabled(model.completing != nil)
        }
        if let feedback = model.offerFeedback, feedback.occurrence == occurrence, feedback.isFailure {
          Text(verbatim: feedback.message).shadowFont(.footnote).foregroundStyle(ShadowColor.dangerText)
        }
      }
    }
    if let feedback = model.offerFeedback, !feedback.isFailure, !feedback.message.isEmpty {
      Text(verbatim: feedback.message).shadowFont(.footnote).foregroundStyle(ShadowColor.successText)
    }
  }

  private func card(_ series: MetricSeries, overview: MetricsOverview) -> some View {
    let metric = series.metric
    let id = metric.reference.id
    let offered = model.offers(for: metric, in: overview).contains { $0.date == overview.window.end }
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: MetricFormat.name(metric)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
            Text(verbatim: series.today.map { MetricFormat.value($0.value, of: metric) } ?? "—").shadowFont(.title2).foregroundStyle(ShadowColor.textPrimary)
            if let today = series.today { Text(verbatim: source(today)).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary) }
          }
          Spacer()
          if offered { ShadowBadge(Text("Threshold met", tableName: "Log"), intent: .success) }
          if metric.builtin == nil { menu(metric) }
        }
        if let builtin = metric.builtin, model.health.showsNoData(builtin, in: series) { HealthNoDataNote() }
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
          TextField(
            text: Binding(get: { model.entry(for: series) }, set: { model.entries[id] = $0 }),
            prompt: Text(verbatim: MetricFormat.inputUnit(metric) ?? "")
          ) {
            Text("\(MetricFormat.name(metric)) for today", tableName: "Log")
          }
          .shadowField()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .shadowValidation(model.problems[id].map { Text(verbatim: $0) })
          .onSubmit { Task { await model.saveEntry(series) } }
          if let unit = MetricFormat.inputUnit(metric) { Text(verbatim: unit).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary) }
          Button {
            Task { await model.saveEntry(series) }
          } label: {
            Text("Save", tableName: "Log")
          }
          .buttonStyle(.shadowBordered)
          .disabled(model.isWriting)
          if series.today.map(isOwnEntry) == true {
            Button {
              Task { await model.clearEntry(series) }
            } label: {
              Text("Clear", tableName: "Log")
            }
            .buttonStyle(.shadowPlain)
            .disabled(model.isWriting)
          }
        }
        LogDayChart(
          LogDayChart.Point.points(series.days) { reading in LogFormat.decimal(reading.value).map { NSDecimalNumber(decimal: $0).doubleValue } },
          label: Text("\(MetricFormat.name(metric)), last 14 days", tableName: "Log"), height: 56
        ) { value in
          Text(verbatim: value.formatted(.number.precision(.fractionLength(0...1))))
        }
      }
    }
  }

  private func isOwnEntry(_ reading: MetricDayReading) -> Bool {
    if case .entry = reading.source { return true }
    return false
  }

  private func source(_ reading: MetricDayReading) -> String {
    switch reading.source {
    case .imported: String(localized: "From Apple Health", table: "Log")
    case .entry: String(localized: "Typed by you", table: "Log")
    }
  }

  private func menu(_ metric: MetricDescriptor) -> some View {
    Menu {
      Button {
        editing = MetricEditing(metric: metric)
      } label: {
        Label {
          Text("Edit metric", tableName: "Log")
        } icon: {
          Image(systemName: "pencil")
        }
      }
      Button(role: .destructive) {
        Task { await model.delete(metric) }
      } label: {
        Label {
          Text("Delete metric", tableName: "Log")
        } icon: {
          Image(systemName: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle").accessibilityLabel(Text("More for \(metric.name)", tableName: "Log"))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

private struct MetricEditing: Identifiable {
  let metric: MetricDescriptor?

  var id: UUID? { metric?.reference.id }
}

/// A metric the owner defines. It is health class unless they say it is not, and a health or activity metric never leaves its own store.
struct MetricFormSheet: View {
  let model: BodyAndHealthModel
  let metric: MetricDescriptor?
  @State private var draft: MetricDraft
  @Environment(\.dismiss) private var dismiss

  init(model: BodyAndHealthModel, metric: MetricDescriptor?) {
    self.model = model
    self.metric = metric
    _draft = State(initialValue: metric.map(MetricDraft.init) ?? MetricDraft())
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        TextField(text: $draft.name, prompt: Text("Glucose", tableName: "Log")) { Text("Name", tableName: "Log") }.shadowField()
        TextField(text: $draft.unit, prompt: Text("mmol/L", tableName: "Log")) { Text("Unit", tableName: "Log") }.shadowField()
        Picker(selection: $draft.valueType) {
          ForEach(MetricDraft.valueTypes, id: \.self) { type in Text(verbatim: valueType(type)).tag(type) }
        } label: {
          Text("Kind of value", tableName: "Log")
        }
        Picker(selection: $draft.direction) {
          ForEach(MetricDirection.allCases, id: \.self) { direction in Text(verbatim: self.direction(direction)).tag(direction) }
        } label: {
          Text("Better when", tableName: "Log")
        }
        Picker(selection: $draft.syncClass) {
          Text("Health data", tableName: "Log").tag(SyncClass.health)
          Text("Activity", tableName: "Log").tag(SyncClass.activity)
          Text("Not health data", tableName: "Log").tag(SyncClass.general)
        } label: {
          Text("What it is", tableName: "Log")
        }
        Text(
          "Health data never syncs through iCloud and stays out of device backups. Activity syncs through iCloud only when you allow it in Sync settings. Changing this later starts the metric again without its days.",
          tableName: "Log"
        )
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        if let failure = model.failure { ShadowCallout(Text("Metric not saved", tableName: "Log"), message: failure.text, intent: .danger) }
      }
      .padding(Spacing.space4)
    }
    .shadowSheetStyle(.form)
    .shadowSheetHeader(
      metric == nil ? Text("New metric", tableName: "Log") : Text("Edit metric", tableName: "Log"),
      cancel: ShadowSheetCancel(Text("Cancel", tableName: "Log")) { dismiss() },
      confirm: ShadowSheetConfirm(Text("Save metric", tableName: "Log"), isDisabled: draft.trimmedName.isEmpty || model.isWriting, submitShortcut: true) {
        Task {
          let saved = if let metric { await model.update(metric, to: draft) } else { await model.create(draft) }
          if saved { dismiss() }
        }
      })
  }

  private func valueType(_ type: MetricValueType) -> String {
    switch type {
    case .number: String(localized: "Number", table: "Log")
    case .count: String(localized: "Count", table: "Log")
    case .duration: String(localized: "Duration", table: "Log")
    case .currency: String(localized: "Amount", table: "Log")
    case .boolean: String(localized: "Yes or no", table: "Log")
    case .text: String(localized: "Text", table: "Log")
    }
  }

  private func direction(_ direction: MetricDirection) -> String {
    switch direction {
    case .higher: String(localized: "Higher", table: "Log")
    case .lower: String(localized: "Lower", table: "Log")
    case .range: String(localized: "In a range", table: "Log")
    case .neutral: String(localized: "No better way", table: "Log")
    }
  }
}

#Preview {
  NavigationStack {
    if let context = try? MemoirScreenContext.inMemory() { BodyAndHealthView(context: context) }
  }
}
