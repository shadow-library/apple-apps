import Foundation
import ShadowCore
import ShadowStore

/// The owner's metric actions. Each writes the record in the store of the metric's class first and then appends its command, if it has one, in the main
/// store, which names the metric by id and class only; a failure between the two leaves a record no command names, never a command naming nothing.
/// Imports from Health go through `HealthImport` and append no command.
public struct MetricCatalog: Sendable {
  public let stores: MemoirStores
  public let issuer: CommandIssuer

  public init(stores: MemoirStores, issuer: CommandIssuer) {
    self.stores = stores
    self.issuer = issuer
  }

  /// A metric the owner creates is health class unless they say it is not.
  public func create(_ definition: MetricDefinition, as syncClass: SyncClass = .health) async throws(MetricsError) -> MetricReference {
    let reference = MetricReference(id: UUID.v7(), metricClass: syncClass)
    try await create(definition, as: reference, syncClass.metricClass)
    return reference
  }

  public func update(_ metric: MetricReference, to definition: MetricDefinition) async throws(MetricsError) {
    try refuseBuiltin(metric)
    try await update(metric, to: definition, metric.metricClass.metricClass)
  }

  /// Removes the definition and keeps the metric's days, as the reference deactivates a metric and never touches its entries.
  public func delete(_ metric: MetricReference, detach: Bool = false) async throws(MetricsError) {
    try refuseBuiltin(metric)
    try await remove(metric, metric.metricClass.metricClass)
    try await issue(.metricDelete(MetricDeletion(metric: metric, detach: detach)))
  }

  /// A class is part of a metric's kind, so changing it creates a new metric in the new class's store and removes the old one. The new metric starts
  /// without days, since moving them would carry one class's values into another's store, and a quest threshold still naming the old metric offers
  /// nothing until it is set again.
  public func reclassify(_ metric: MetricReference, as syncClass: SyncClass) async throws(MetricsError) -> MetricReference {
    try refuseBuiltin(metric)
    guard metric.metricClass != syncClass else { return metric }
    let definition = try await definition(of: metric, metric.metricClass.metricClass)
    let created = try await create(definition, as: syncClass)
    try await delete(metric)
    return created
  }

  /// The owner's value for a day: it wins over a Health import of the same day for as long as it is set. Only a general metric's entry appends
  /// `metric.register`; for an activity or health metric the day record is the whole effect, as the reference's `registerEntry` moves no ledger, so the
  /// main store never learns on which days such a metric was logged.
  public func register(_ value: DecimalText, for metric: MetricReference, on date: LocalDate, source: MetricEntrySource = .manual, questLog: Occurrence? = nil)
    async throws(MetricsError)
  {
    if source == .questLog, questLog == nil { throw .refused(.invalidField(field: "questLogId", problem: .required)) }
    try await enter(MetricEntry(value: value, source: .known(source)), for: metric, on: date, metric.metricClass.metricClass)
    guard metric.metricClass == .general else { return }
    try await issue(.metricRegister(MetricRegistration(metric: metric, date: date, source: source, questLog: questLog)))
  }

  /// Clears the owner's entry, so a Health import of the day shows again. The reference has no command for this.
  public func clearEntry(for metric: MetricReference, on date: LocalDate) async throws(MetricsError) {
    try await enter(nil, for: metric, on: date, metric.metricClass.metricClass)
  }

  private func refuseBuiltin(_ metric: MetricReference) throws(MetricsError) {
    if let builtin = BuiltinMetric(id: metric.id) { throw .builtinFixed(builtin) }
  }

  private func create<Class: MetricClass>(_ definition: MetricDefinition, as reference: MetricReference, _: Class.Type) async throws(MetricsError) {
    let record = definition.record(MetricID<Class>(recordUUID: reference.id))
    do throws(CommandRefusal) {
      try record.validate()
    } catch {
      throw .refused(error)
    }
    try await metricsCall { () async throws(StoreError) in try await stores.store(of: Class.syncClass).write { transaction in try record.create(in: &transaction) } }
    try await issue(.metricCreate(reference), content: record)
  }

  private func update<Class: MetricClass>(_ metric: MetricReference, to definition: MetricDefinition, _: Class.Type) async throws(MetricsError) {
    let updated = definition.record(MetricID<Class>(recordUUID: metric.id))
    do throws(CommandRefusal) {
      try updated.validate()
    } catch {
      throw .refused(error)
    }
    try await metricsCall { () async throws(StoreError) in
      try await stores.store(of: Class.syncClass).write { transaction in
        _ = try Self.present(metric, Class.self, in: transaction)
        try MetricRecord<Class>.edit(id: updated.id, in: &transaction) { $0 = updated }
      }
    }
    try await issue(.metricUpdate(metric), content: updated)
  }

  private func remove<Class: MetricClass>(_ metric: MetricReference, _: Class.Type) async throws(MetricsError) {
    try await metricsCall { () async throws(StoreError) in
      try await stores.store(of: Class.syncClass).write { transaction in
        _ = try Self.present(metric, Class.self, in: transaction)
        try MetricRecord<Class>.remove(MetricRecord<Class>.ref(MetricID(recordUUID: metric.id)), in: &transaction)
      }
    }
  }

  private func definition<Class: MetricClass>(of metric: MetricReference, _: Class.Type) async throws(MetricsError) -> MetricDefinition {
    try await metricsCall { () async throws(StoreError) in
      try await stores.store(of: Class.syncClass).read { transaction in
        let record = try Self.present(metric, Class.self, in: transaction)
        guard let valueType = record.valueType.known else { throw MetricsError.refused(.invalidField(field: "valueType", problem: .notAllowed)) }
        guard let direction = record.direction.known else { throw MetricsError.refused(.invalidField(field: "direction", problem: .notAllowed)) }
        return MetricDefinition(
          name: record.name, unit: record.unit, valueType: valueType, direction: direction, defaultValue: record.defaultValue, glyph: record.glyph)
      }
    }
  }

  private func enter<Class: MetricClass>(_ entry: MetricEntry?, for metric: MetricReference, on date: LocalDate, _: Class.Type) async throws(MetricsError) {
    let id = MetricID<Class>(recordUUID: metric.id)
    try await metricsCall { () async throws(StoreError) in
      try await stores.store(of: Class.syncClass).write { transaction in
        try BuiltinMetric.seed(id, in: &transaction)
        _ = try Self.present(metric, Class.self, in: transaction)
        try MetricDays.enter(entry, for: id, on: date, in: &transaction)
      }
    }
  }

  private func issue(_ body: MemoirCommandBody) async throws(MetricsError) {
    let issuer = issuer
    try await metricsCall { () async throws(StoreError) in try await stores.main.write { transaction in try issuer.issue(body, in: &transaction) } }
  }

  private func issue<Content: CommandContent & Sendable>(_ body: MemoirCommandBody, content: Content) async throws(MetricsError) {
    let issuer = issuer
    try await metricsCall { () async throws(StoreError) in try await stores.main.write { transaction in try issuer.issue(body, content: content, in: &transaction) } }
  }

  private static func present<Class: MetricClass, Source: RecordSource & ~Copyable>(_ metric: MetricReference, _: Class.Type, in source: borrowing Source) throws
    -> MetricRecord<Class>
  {
    guard case .readable(let entry) = try MetricRecord<Class>.read(id: MetricID(recordUUID: metric.id), in: source), !entry.isRemoved else {
      throw MetricsError.metricAbsent(metric)
    }
    return entry.record
  }
}
