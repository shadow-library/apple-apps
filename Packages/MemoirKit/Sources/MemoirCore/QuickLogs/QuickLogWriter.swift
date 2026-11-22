import Foundation
import ShadowCore
import ShadowStore

public enum QuickLogError: ShadowError {
  case store(StoreError)
  case record(MemoirRecordError)
  case issue(CommandIssueError)

  public var code: String {
    switch self {
    case .store(let error): error.code
    case .record(let error): error.code
    case .issue(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .issue(let error): error.errorDescription
    }
  }

  init(_ error: StoreError) {
    switch error {
    case .aborted(let inner as QuickLogError): self = inner
    case .aborted(let inner as MemoirRecordError): self = .record(inner)
    case .aborted(let inner as CommandIssueError): self = .issue(inner)
    default: self = .store(error)
    }
  }
}

public enum WeightSave: Sendable, Equatable {
  case saved(MemoirCommand)
  case needsConfirmation(existing: WeightRecord)
}

/// Quick logs routed by class: a weight is health class, so its record goes to the restricted store and only `weight.save`, naming the date, to the main
/// store, written after the record; the other quick logs are general and are written with their command in one main-store write. Each action takes its
/// issuer from the main store as it then stands: the weight's when it starts, since the record carries the command's instant, the others' in their write.
///
/// A failure between a weight's two writes leaves a record no `weight.save` names, which replay never counted; saving that day again replaces the orphan
/// and appends the command without asking, as a first save of the day. Only a record this store's replica wrote last is taken for an orphan: another
/// device's record can arrive through the restricted store's sync before its command arrives through the main store's, and that one is asked about.
public struct QuickLogWriter: Sendable {
  public let stores: MemoirStores
  public let issuer: CommandIssuerSource

  public init(stores: MemoirStores, issuer: CommandIssuerSource) {
    self.stores = stores
    self.issuer = issuer
  }

  /// Replacing a day's weight needs `confirmedReplacement`, as `weight.save` asks the reference for it.
  public func saveWeight(_ kilograms: DecimalText, on date: LocalDate, confirmedReplacement: Bool = false) async throws(QuickLogError) -> WeightSave {
    let body = MemoirCommandBody.weightSave(WeightEntry(date: date, confirmedReplacement: confirmedReplacement))
    let source = issuer
    let issuer = try await call { () async throws(StoreError) in try await stores.main.read { transaction in try source.issuer(in: transaction) } }
    let command: MemoirCommand
    do throws(CommandIssueError) {
      command = try issuer.command(body)
    } catch {
      throw .issue(error)
    }
    let record = WeightRecord(date: date, kilograms: kilograms, loggedAtMillis: command.instantMillis)
    do throws(CommandRefusal) {
      try record.validate()
    } catch {
      throw .issue(.refused(error))
    }
    let restricted = stores.restricted
    let replica = restricted.replica
    let existing = try await call { () async throws(StoreError) in
      try await restricted.write { transaction -> (record: WeightRecord, writtenHere: Bool)? in
        let current = try WeightRecord.read(key: record.key, in: transaction)
        switch current {
        case .absent:
          try record.create(in: &transaction)
        case .unreadable(let reason):
          throw MemoirRecordError.unreadable(record.ref, reason)
        case .readable(let entry):
          if !entry.isRemoved, !confirmedReplacement { return (entry.record, try Self.isLastWritten(record.ref, by: replica, in: transaction)) }
          if entry.isRemoved { try WeightRecord.restore(record.ref, in: &transaction) }
          try WeightRecord.edit(record.ref, in: &transaction) { $0 = record }
        }
        return nil
      }
    }
    if let existing {
      guard existing.writtenHere else { return .needsConfirmation(existing: existing.record) }
      let recorded = try await call { () async throws(StoreError) in try await stores.main.read { transaction in try Self.isWeightSaved(on: date, in: transaction) } }
      if recorded { return .needsConfirmation(existing: existing.record) }
      try await call { () async throws(StoreError) in
        try await restricted.write { transaction in try WeightRecord.edit(record.ref, in: &transaction) { $0 = record } }
      }
    }
    try await call { () async throws(StoreError) in try await stores.main.write { transaction in try command.append(in: &transaction) } }
    return .saved(command)
  }

  /// Whether a `weight.save` names `date`. One this version cannot read may name it, so it counts as present and the owner is asked. It reads every
  /// command's stored item but decodes only the `weight.save` ones, and runs only when the day's record already exists and this replica wrote it last.
  static func isWeightSaved(on date: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    for (ref, state) in try transaction.states(ofKind: MemoirCommand.kind.entityKind) {
      guard case .appended(let appended) = state, appended.item["type"]?.stringValue == MemoirCommandKind.weightSave.rawValue else { continue }
      guard case .readable(let entry) = MemoirCommand.reading(state, of: ref), case .weightSave(let saved) = try? MemoirCommandBody(entry.record) else { return true }
      if saved.date == date { return true }
    }
    return false
  }

  /// Whether the record's newest field was written by `replica`; a state of another shape was not written here.
  private static func isLastWritten(_ ref: EntityRef, by replica: ReplicaID, in transaction: borrowing WriteTransaction) throws(StoreError) -> Bool {
    guard case .record(let state) = try transaction.state(of: ref), let newest = state.fields.values.map(\.clock).max() else { return false }
    return newest.replica == replica
  }

  /// A general-class quick log (journal entry, meal, side quest, meal preset) and its command, in one main-store write.
  @discardableResult
  public func log<Record: MemoirRecord & CommandContent>(_ record: Record, as body: MemoirCommandBody) async throws(QuickLogError) -> MemoirCommand {
    let source = issuer
    let main = stores.main
    return try await call { () async throws(StoreError) in
      try await main.write { transaction in
        let command = try source.issuer(in: transaction, of: main).issue(body, content: record, in: &transaction)
        try record.create(in: &transaction)
        return command
      }
    }
  }

  @discardableResult
  private func call<T>(_ body: () async throws(StoreError) -> T) async throws(QuickLogError) -> T {
    do {
      return try await body()
    } catch {
      throw QuickLogError(error)
    }
  }
}
