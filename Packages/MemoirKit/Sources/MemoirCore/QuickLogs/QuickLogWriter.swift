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
/// store, written after the record; the other quick logs are general and are written with their command in one main-store write.
public struct QuickLogWriter: Sendable {
  public let stores: MemoirStores
  public let issuer: CommandIssuer

  public init(stores: MemoirStores, issuer: CommandIssuer) {
    self.stores = stores
    self.issuer = issuer
  }

  /// Replacing a day's weight needs `confirmedReplacement`, as `weight.save` asks the reference for it.
  public func saveWeight(_ kilograms: DecimalText, on date: LocalDate, confirmedReplacement: Bool = false) async throws(QuickLogError) -> WeightSave {
    let body = MemoirCommandBody.weightSave(WeightEntry(date: date, confirmedReplacement: confirmedReplacement))
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
    let existing = try await call { () async throws(StoreError) in
      try await stores.restricted.write { transaction -> WeightRecord? in
        let current = try WeightRecord.read(key: record.key, in: transaction)
        switch current {
        case .absent:
          try record.create(in: &transaction)
        case .unreadable(let reason):
          throw MemoirRecordError.unreadable(record.ref, reason)
        case .readable(let entry):
          if !entry.isRemoved, !confirmedReplacement { return entry.record }
          if entry.isRemoved { try WeightRecord.restore(record.ref, in: &transaction) }
          try WeightRecord.edit(record.ref, in: &transaction) { $0 = record }
        }
        return nil
      }
    }
    if let existing { return .needsConfirmation(existing: existing) }
    try await call { () async throws(StoreError) in try await stores.main.write { transaction in try command.append(in: &transaction) } }
    return .saved(command)
  }

  /// A general-class quick log (journal entry, meal, side quest, meal preset) and its command, in one main-store write.
  @discardableResult
  public func log<Record: MemoirRecord & CommandContent>(_ record: Record, as body: MemoirCommandBody) async throws(QuickLogError) -> MemoirCommand {
    let issuer = issuer
    return try await call { () async throws(StoreError) in
      try await stores.main.write { transaction in
        let command = try issuer.issue(body, content: record, in: &transaction)
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
