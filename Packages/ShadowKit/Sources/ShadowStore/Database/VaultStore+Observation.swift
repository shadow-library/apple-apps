import GRDB
import Synchronization

extension VaultStore {
  /// Emits the value once, then again after each committed transaction, local or remote, that changed it; only the latest value is kept for a slow consumer.
  /// GRDB's table observation cannot be used: the kernel tables are `WITHOUT ROWID` and SQLite reports no row changes for those, so every commit is the signal.
  public func observeReads<Value: Sendable & Equatable>(_ read: @escaping @Sendable (ReadTransaction) throws -> Value) -> AsyncThrowingStream<Value, any Error> {
    observeReads(after: CommitObserver.Trigger.anyCommit, read)
  }

  /// `observeReads(_:)` for a value read from `tables` alone: it reads again only after a commit with a statement that wrote to one of them, `WITHOUT ROWID`
  /// tables included, as GRDB's authorizer names them before each statement runs.
  public func observeReads<Value: Sendable & Equatable>(
    writingTo tables: Set<String>, _ read: @escaping @Sendable (ReadTransaction) throws -> Value
  ) -> AsyncThrowingStream<Value, any Error> {
    observeReads(after: .writes(Set(tables.map { $0.lowercased() })), read)
  }

  private func observeReads<Value: Sendable & Equatable>(
    after trigger: CommitObserver.Trigger, _ read: @escaping @Sendable (ReadTransaction) throws -> Value
  ) -> AsyncThrowingStream<Value, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (commits, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let observer = CommitObserver(signal, trigger: trigger)
    let task = Task {
      do {
        try await addCommitObserver(observer)
        var last: Value?
        repeat {
          let value = try await reading { database in try read(ReadTransaction(database: database, registry: self.registry)) }
          if value != last { continuation.yield(value) }
          last = value
        } while await commits.first(where: { _ in true }) != nil
        continuation.finish()
      } catch {
        continuation.finish(throwing: StoreError(converting: error))
      }
    }
    continuation.onTermination = { @Sendable _ in
      task.cancel()
      signal.finish()
      self.removeCommitObserver(observer)
    }
    return stream
  }
}

private final class CommitObserver: TransactionObserver, Sendable {
  enum Trigger: Sendable {
    case anyCommit
    case writes(Set<String>)
  }

  private let signal: AsyncStream<Void>.Continuation
  private let trigger: Trigger
  private let wrote = Mutex(false)

  init(_ signal: AsyncStream<Void>.Continuation, trigger: Trigger) {
    self.signal = signal
    self.trigger = trigger
  }

  /// GRDB asks this before each statement runs, for every table the statement (with its triggers) may write; answering false keeps row events away.
  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
    if case .writes(let tables) = trigger, tables.contains(eventKind.tableName.lowercased()) { wrote.withLock { $0 = true } }
    return false
  }

  func databaseDidChange(with event: DatabaseEvent) {}

  func databaseDidCommit(_ db: Database) {
    let relevant = wrote.withLock { wrote in
      defer { wrote = false }
      return wrote
    }
    if case .writes = trigger, !relevant { return }
    signal.yield()
  }

  func databaseDidRollback(_ db: Database) {
    wrote.withLock { $0 = false }
  }
}
