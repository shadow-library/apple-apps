import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

/// What the owner says a metric is: its name, unit, kind of value, which way is better, and whether it is health data.
nonisolated struct MetricDraft: Equatable, Sendable {
  static let valueTypes: [MetricValueType] = [.number, .count, .duration]

  var name = ""
  var unit = ""
  var valueType = MetricValueType.number
  var direction = MetricDirection.higher
  /// A metric the owner creates is health class unless they say it is not.
  var syncClass = SyncClass.health

  init() {}

  init(_ metric: MetricDescriptor) {
    name = metric.name
    unit = metric.unit ?? ""
    if case .known(let type) = metric.valueType { valueType = type }
    if case .known(let direction) = metric.direction { self.direction = direction }
    syncClass = metric.reference.metricClass
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var definition: MetricDefinition {
    let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
    return MetricDefinition(name: trimmedName, unit: unit.isEmpty ? nil : unit, valueType: valueType, direction: direction)
  }
}

/// `features/quick-logs/health-screen.tsx`: each metric's day, typed by hand or read from Health, its last 14 days, and the quests whose threshold a
/// day crosses. Each metric is read and written only in the store of its class; accepting an offer is the owner's own `quest.complete`, issued through
/// the quest actions, so nothing here completes a quest by itself.
@MainActor
@Observable
final class BodyAndHealthModel {
  struct OfferFeedback: Equatable {
    let occurrence: Occurrence
    let message: String
    let isFailure: Bool
  }

  nonisolated struct Key: Equatable, Sendable {
    let today: LocalDate
    let activeQuests: [UUID]
  }

  let context: MemoirScreenContext
  let overview = ReadObserver<MetricsOverview>()
  let actions: QuestActionsModel
  let health: HealthReadingModel
  var entries: [UUID: String] = [:]
  private(set) var problems: [UUID: String] = [:]
  private(set) var isWriting = false
  private(set) var busy: UUID?
  private(set) var completing: Occurrence?
  private(set) var failure: PresentedError?
  private(set) var confirmation: String?
  private(set) var offerFeedback: OfferFeedback?
  private let locale: Locale

  init(context: MemoirScreenContext, health: HealthReadingModel? = nil, locale: Locale = .current) {
    self.context = context
    actions = QuestActionsModel(writer: context.writer)
    self.health = health ?? HealthReadingModel(context: context)
    self.locale = locale
  }

  func observe() async {
    let context = context
    let stores = context.stores
    let clock = context.clock
    let keys = stores.main.observeReads { transaction in
      Key(today: try clock.today(in: try AccountZone.load(in: transaction)).date, activeQuests: try QuestList.load(QuestListQuery(), in: transaction).entries.map(\.id))
    }
    async let overview: Void = overview.run {
      LogStreams.following(keys) { key in
        LogReads.observeMetrics(in: stores, classes: Set(SyncClass.allCases), activeQuests: key.activeQuests, today: key.today)
      }
    }
    async let health: Void = health.observe()
    _ = await (overview, health)
  }

  /// What the field shows: what the owner typed, else the day's value, so saving it again changes nothing.
  func entry(for series: MetricSeries) -> String {
    entries[series.metric.reference.id] ?? series.today.map { MetricFormat.input($0.value, of: series.metric, locale: locale) } ?? ""
  }

  func offers(for metric: MetricDescriptor, in overview: MetricsOverview) -> [ThresholdOffer] {
    overview.offers.filter { $0.metric == metric.reference }
  }

  @discardableResult
  func saveEntry(_ series: MetricSeries) async -> Bool {
    let metric = series.metric
    let id = metric.reference.id
    switch MetricFormat.stored(entry(for: series), for: metric, locale: locale) {
    case .failure(let problem):
      problems[id] = problem.message(for: MetricFormat.name(metric), locale: locale)
      return false
    case .success(let value):
      problems[id] = nil
      let saved = await write(id, success: String(localized: "\(MetricFormat.name(metric)) saved.", table: "Log")) { context, today in
        try await context.writer.metrics.register(value, for: metric.reference, on: today)
      }
      if saved { entries[id] = nil }
      return saved
    }
  }

  /// Clears the owner's own value for today, so a Health import of the day shows again.
  @discardableResult
  func clearEntry(_ series: MetricSeries) async -> Bool {
    let metric = series.metric
    let saved = await write(metric.reference.id, success: String(localized: "\(MetricFormat.name(metric)) cleared.", table: "Log")) { context, today in
      try await context.writer.metrics.clearEntry(for: metric.reference, on: today)
    }
    if saved { entries[metric.reference.id] = nil }
    return saved
  }

  @discardableResult
  func create(_ draft: MetricDraft) async -> Bool {
    guard !draft.trimmedName.isEmpty else { return false }
    return await write(nil, success: String(localized: "\(draft.trimmedName) added.", table: "Log")) { context, _ in
      _ = try await context.writer.metrics.create(draft.definition, as: draft.syncClass)
    }
  }

  /// A metric's class is part of what it is: changing it makes a new metric in the new class's store, without the old one's days.
  @discardableResult
  func update(_ metric: MetricDescriptor, to draft: MetricDraft) async -> Bool {
    guard metric.builtin == nil, !draft.trimmedName.isEmpty else { return false }
    return await write(metric.reference.id, success: String(localized: "\(draft.trimmedName) saved.", table: "Log")) { context, _ in
      var reference = metric.reference
      if draft.syncClass != reference.metricClass { reference = try await context.writer.metrics.reclassify(reference, as: draft.syncClass) }
      try await context.writer.metrics.update(reference, to: draft.definition)
    }
  }

  /// Removes the definition and keeps its days, as the reference deactivates a metric.
  @discardableResult
  func delete(_ metric: MetricDescriptor) async -> Bool {
    guard metric.builtin == nil else { return false }
    return await write(metric.reference.id, success: String(localized: "\(MetricFormat.name(metric)) deleted.", table: "Log")) { context, _ in
      try await context.writer.metrics.delete(metric.reference)
    }
  }

  /// Consent, never automation: accepting an offer issues the owner's own `quest.complete` for that day, through the same checks Today makes.
  func complete(_ offer: ThresholdOffer) async {
    let occurrence = Occurrence(quest: offer.quest, date: offer.date)
    guard completing == nil else { return }
    completing = occurrence
    defer { completing = nil }
    let row: BoardOccurrence?
    do {
      row = try await context.stores.main.load(TodayBoard.self, TodayBoardQuery(date: offer.date)).occurrences.first { $0.id == occurrence }
    } catch {
      offerFeedback = OfferFeedback(
        occurrence: occurrence, message: QuestActionCopy.failure(.complete, name: offer.questName, message: PresentedError(error).headline), isFailure: true)
      return
    }
    switch await actions.perform(.complete(occurrence), on: row, at: nil) {
    case .done:
      offerFeedback = OfferFeedback(occurrence: occurrence, message: row.map { QuestActionCopy.success(.complete(occurrence), for: $0) } ?? "", isFailure: false)
    case .unavailable(let reason):
      offerFeedback = OfferFeedback(occurrence: occurrence, message: QuestActionCopy.unavailable(reason, for: .complete) ?? "", isFailure: true)
    case .failed(let error):
      offerFeedback = OfferFeedback(occurrence: occurrence, message: QuestActionCopy.failure(.complete, name: offer.questName, message: error.headline), isFailure: true)
    case .cancelled:
      offerFeedback = nil
    }
  }

  private func write(_ metric: UUID?, success: String, _ body: (MemoirScreenContext, LocalDate) async throws -> Void) async -> Bool {
    guard !isWriting else { return false }
    isWriting = true
    busy = metric
    defer {
      isWriting = false
      busy = nil
    }
    failure = nil
    confirmation = nil
    do {
      try await body(context, try await context.today().date)
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
    confirmation = success
    return true
  }
}
