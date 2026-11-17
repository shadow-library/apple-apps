import GRDB

extension VaultStore {
  /// Emits the value once, then again after each committed transaction, local or remote, that changed it; only the latest value is kept for a slow consumer.
  /// GRDB's table observation cannot be used: the kernel tables are `WITHOUT ROWID` and SQLite reports no row changes for those, so every commit is the signal.
  public func observeReads<Value: Sendable & Equatable>(_ read: @escaping @Sendable (ReadTransaction) throws -> Value) -> AsyncThrowingStream<Value, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (commits, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let observer = CommitObserver(signal)
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
  private let signal: AsyncStream<Void>.Continuation

  init(_ signal: AsyncStream<Void>.Continuation) {
    self.signal = signal
  }

  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }

  func databaseDidChange(with event: DatabaseEvent) {}

  func databaseDidCommit(_ db: Database) {
    signal.yield()
  }

  func databaseDidRollback(_ db: Database) {}
}
