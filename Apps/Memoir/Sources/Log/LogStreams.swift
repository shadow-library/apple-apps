import Foundation
import MemoirCore
import ShadowStore

nonisolated enum LogStreams {
  /// Follows the latest key: each new key cancels the read started for the previous one and starts its own, so a read model built for a day moves to
  /// the next day when the account's day turns.
  static func following<Key: Equatable & Sendable, Value: Sendable>(
    _ keys: AsyncThrowingStream<Key, any Error>, _ make: @escaping @Sendable (Key) -> AsyncThrowingStream<Value, any Error>
  ) -> AsyncThrowingStream<Value, any Error> {
    AsyncThrowingStream { continuation in
      let outer = Task {
        var inner: Task<Void, Never>?
        do {
          var last: Key?
          for try await key in keys {
            if key == last { continue }
            last = key
            inner?.cancel()
            inner = Task {
              do {
                for try await value in make(key) {
                  guard !Task.isCancelled else { return }
                  continuation.yield(value)
                }
              } catch is CancellationError {
                return
              } catch {
                continuation.finish(throwing: error)
              }
            }
          }
          if let current = inner, !Task.isCancelled {
            await withTaskCancellationHandler {
              await current.value
            } onCancel: {
              current.cancel()
            }
          }
          inner?.cancel()
          continuation.finish()
        } catch {
          inner?.cancel()
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in outer.cancel() }
    }
  }

  /// The account's day, again after each commit that moves it.
  static func days(_ context: MemoirScreenContext) -> AsyncThrowingStream<LocalDate, any Error> {
    let clock = context.clock
    return context.stores.main.observeReads { transaction in try clock.today(in: try AccountZone.load(in: transaction)).date }
  }

  static func entryCaps(_ context: MemoirScreenContext, includeHealth: Bool = false) -> AsyncThrowingStream<EntryCapsOverview, any Error> {
    let stores = context.stores
    return following(days(context)) { today in LogReads.observeEntryCaps(in: stores, today: today, includeHealth: includeHealth) }
  }
}
