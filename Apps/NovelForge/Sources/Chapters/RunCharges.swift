import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowDesignSystem
import ShadowJobs
import SwiftUI

/// apps/novel-forge-web/src/features/usage/RunCharges.tsx:95-139 and UsageParts.tsx:128-137; the reference lists a novel's runs and has no chapter total.
enum RunChargesDisplay {
  nonisolated enum State: Equatable, Sendable {
    case unavailable
    case empty
    case runs([RunCharge], total: JobCost)
  }

  static func state(runs: Derived<[RunCharge]>, total: Derived<JobCost>) -> State {
    guard let runs = runs.value, let total = total.value else { return .unavailable }
    return runs.isEmpty ? .empty : .runs(runs, total: total)
  }

  static func amount(_ cost: JobCost) -> String {
    amount(cost.cost, estimated: cost.estimated, pending: cost.isPending)
  }

  static func amount(_ cost: Cost, estimated: Cost, pending: Bool) -> String {
    if pending { return String(localized: "cost pending", table: "Costs") }
    let figure = ChatReplyTag.usd(cost)
    return estimated.nanoUSD > 0 ? figure + "*" : figure
  }

  static func detail(_ cost: JobCost) -> String {
    let calls = String(localized: "\(cost.calls) calls", table: "Costs")
    guard cost.calls > 0 else { return calls }
    return String(localized: "\(calls) · \(tokens(cost.usage)) tokens", table: "Costs")
  }

  static func title(_ run: RunCharge) -> Text {
    guard case .known(let kind) = run.kind else { return Text("Another job", tableName: "Costs") }
    return JobDisplay.title(kind)
  }

  static func when(_ run: RunCharge) -> String {
    let time = ChatReplyTag.time(run.requested)
    guard run.run > 1 else { return time }
    return String(localized: "Run \(run.run) · \(time)", table: "Costs")
  }

  // apps/novel-forge-web/src/lib/usage.ts:166-171
  static func tokens(_ usage: TokenUsage) -> String {
    let value = usage.input.addingReportingOverflow(usage.output).partialValue
    if value < 1_000 { return value.formatted() }
    if value < 100_000 { return trimmed(Double(value) / 1_000) + "k" }
    if value < 1_000_000 { return "\(Int((Double(value) / 1_000).rounded()))k" }
    return trimmed(Double(value) / 1_000_000) + "M"
  }

  private static func trimmed(_ value: Double) -> String {
    let text = String(format: "%.1f", value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
  }
}

struct RunCharges: View {
  let context: NovelContext
  let chapter: Int
  @State private var charges = ReadObserver<ChapterRunCharges>()

  var body: some View {
    content
      .task {
        let (store, novel, chapter) = (context.store, context.novel, chapter)
        await charges.run { store.observe(ChapterRunCharges.self, ChapterRunChargesQuery(novel: novel, chapter: chapter)) }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch charges.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 200)
    case .failed(let error):
      unavailable(error.text)
    case .loaded(let charges):
      loaded(charges)
    }
  }

  @ViewBuilder
  private func loaded(_ loaded: ChapterRunCharges) -> some View {
    switch RunChargesDisplay.state(runs: loaded.runs, total: loaded.total) {
    case .unavailable:
      unavailable(Text("The costs of this chapter can't be read on this device right now.", tableName: "Costs"))
    case .empty:
      ShadowContentUnavailable(
        Text("No runs yet", tableName: "Costs"), systemImage: "creditcard",
        message: Text("Every time the AI writes or checks this chapter, it shows up here with what it cost.", tableName: "Costs")
      )
      .frame(maxWidth: .infinity, minHeight: 200)
    case .runs(let runs, let total):
      list(runs, total: total)
    }
  }

  private func unavailable(_ message: Text) -> some View {
    ShadowContentUnavailable(Text("Unavailable", tableName: "Costs"), kind: .error, message: message).frame(maxWidth: .infinity, minHeight: 200)
  }

  private func list(_ runs: [RunCharge], total: JobCost) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowGroupedSection {
        figure(Text("Chapter \(chapter)", tableName: "Costs"), detail: RunChargesDisplay.detail(total), cost: total, prominent: true)
      }
      ShadowGroupedSection {
        ForEach(Array(runs.enumerated()), id: \.element.job) { index, run in
          if index > 0 { Divider() }
          figure(RunChargesDisplay.title(run), detail: RunChargesDisplay.when(run) + " · " + RunChargesDisplay.detail(run.cost), cost: run.cost, prominent: false)
        }
      } header: {
        Text("Runs", tableName: "Costs").shadowFont(.headline)
      }
      if runs.contains(where: { $0.cost.estimated.nanoUSD > 0 }) || total.estimated.nanoUSD > 0 {
        Text("* Includes an estimate from catalog prices.", tableName: "Costs").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private func figure(_ title: Text, detail: String, cost: JobCost, prominent: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        title.shadowFont(prominent ? .headline : .body)
        Text(verbatim: detail).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
      Spacer(minLength: Spacing.space3)
      Text(verbatim: RunChargesDisplay.amount(cost))
        .shadowFont(prominent ? .headline : .body)
        .foregroundStyle(cost.isPending ? ShadowColor.warningText : ShadowColor.textPrimary)
        .monospacedDigit()
    }
    .padding(Spacing.space3)
    .accessibilityElement(children: .combine)
  }
}
