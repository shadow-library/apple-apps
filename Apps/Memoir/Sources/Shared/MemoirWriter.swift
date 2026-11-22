import Foundation
import MemoirCore
import ShadowCore
import ShadowStore

nonisolated enum MemoirWriteError: DomainFailure {
  case command(CommandIssueError)
  case record(MemoirRecordError)
  case recordNotGeneral(MemoirKind)
  case clock(CalendarError)
  case store(StoreError)
  /// The task that wrote was cancelled, as when its screen went away; nothing was written and there is nothing to show.
  case cancelled

  var code: String {
    switch self {
    case .command(let error): error.code
    case .record(let error): error.code
    case .recordNotGeneral: "memoir_write.record_not_general"
    case .clock(let error): error.code
    case .store(let error): error.code
    case .cancelled: "memoir_write.cancelled"
    }
  }

  var errorDescription: String? {
    switch self {
    case .command(let error): error.errorDescription
    case .record(let error): error.errorDescription
    case .recordNotGeneral(let kind): "\(kind.rawValue) is \(kind.syncClass.rawValue) class and belongs in its own store, never the main one."
    case .clock(let error): error.errorDescription
    case .store(let error): error.errorDescription
    case .cancelled: "The write was cancelled before it finished."
    }
  }

  var storeFailure: StoreError? {
    switch self {
    case .store(let error), .record(.store(let error)), .command(.record(.store(let error))): error
    case .command, .record, .recordNotGeneral, .clock, .cancelled: nil
    }
  }

  /// GRDB reports a cancelled task's access, an interrupted statement included, only as `CancellationError` (`Database+Statements.swift`), which the
  /// store wraps as `.aborted`.
  init(_ error: StoreError) {
    switch error {
    case .aborted(let inner as MemoirWriteError): self = inner
    case .aborted(is CancellationError): self = .cancelled
    case .aborted(let inner as CommandIssueError): self = .command(inner)
    case .aborted(let inner as CommandRefusal): self = .command(.refused(inner))
    case .aborted(let inner as MemoirCommandError): self = .command(.command(inner))
    case .aborted(let inner as FinanceError): self = .command(.finance(inner))
    case .aborted(let inner as MemoirRecordError): self = .record(inner)
    case .aborted(let inner as CalendarError): self = .clock(inner)
    default: self = .store(error)
    }
  }
}

/// How Memoir screens write to the main store: each call is one write, and its commands are stamped with the clock in force on the account's day (the
/// staged zone once that day has passed, the device's zone only before any zone is set) at the trusted now, read inside that write.
nonisolated struct MemoirWriter: Sendable {
  let stores: MemoirStores
  let clock: MemoirClock

  @discardableResult
  func issue(_ body: MemoirCommandBody, text: String? = nil) async throws(MemoirWriteError) -> MemoirCommand {
    try await write { issuer, transaction in try issuer.issue(body, text: text, in: &transaction) }
  }

  /// Creates the record the command names and issues the command after the reference's checks on it, in one write. Only a general-class record lives in
  /// the main store; the others go through `quickLogs` and `metrics`.
  @discardableResult
  func issue<Record: MemoirRecord & CommandContent>(_ body: MemoirCommandBody, text: String? = nil, creating record: Record) async throws(MemoirWriteError)
    -> MemoirCommand
  {
    guard Record.kind.syncClass == .general else { throw .recordNotGeneral(Record.kind) }
    return try await write { issuer, transaction in
      let command = try issuer.issue(body, text: text, content: record, in: &transaction)
      try record.create(in: &transaction)
      return command
    }
  }

  /// Writes records and commands together: anything the closure throws rolls back the whole write.
  func write<T: Sendable>(_ body: @Sendable (CommandIssuer, inout WriteTransaction) throws -> T) async throws(MemoirWriteError) -> T {
    let main = stores.main
    let source = clock.issuerSource
    do {
      return try await main.write { transaction in try body(try source.issuer(in: transaction, of: main), &transaction) }
    } catch {
      throw MemoirWriteError(error)
    }
  }

  /// Weights, whose records are health class, with their commands stamped as each is written.
  var quickLogs: QuickLogWriter { QuickLogWriter(stores: stores, issuer: clock.issuerSource) }

  /// Metrics and their days in the store of each metric's class, with their commands stamped as each is written.
  var metrics: MetricCatalog { MetricCatalog(stores: stores, issuer: clock.issuerSource) }

  func accountZone() async throws(MemoirWriteError) -> AccountZone {
    do {
      return try await AccountZone.load(from: stores.main)
    } catch {
      throw MemoirWriteError(error)
    }
  }
}
