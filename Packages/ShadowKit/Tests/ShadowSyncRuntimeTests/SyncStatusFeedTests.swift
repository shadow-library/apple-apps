import Foundation
import Synchronization
import Testing

@testable import ShadowSyncRuntime

@Suite("SyncStatusFeed", TestTimeLimit.quick)
struct SyncStatusFeedTests {
  @Test func shouldNeverDeadlockWhenASubscriberIsCancelledWhileAStatusIsPublished() async {
    let feed = SyncStatusFeed(.off)
    let rounds = Task.detached {
      for _ in 0..<2_000 {
        let stream = feed.stream()
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let consumer = Task.detached {
          var updates = stream.makeAsyncIterator()
          _ = await updates.next()
          didStart.yield()
          while await updates.next() != nil {}
        }
        for await _ in started { break }
        let publisher = Task.detached {
          for step in 0..<200 { feed.publish(step.isMultiple(of: 2) ? .syncing : .upToDate) }
        }
        consumer.cancel()
        await publisher.value
        await consumer.value
      }
      return true
    }
    let finished = await Self.first(of: rounds, orFalseAfter: .seconds(60))
    #expect(finished, "publishing and cancelling a subscriber at once deadlocked")
  }

  /// A deadlocked task never finishes, so the race returns without waiting for it.
  private static func first(of task: Task<Bool, Never>, orFalseAfter limit: Duration) async -> Bool {
    let once = Once()
    return await withCheckedContinuation { continuation in
      let answer: @Sendable (Bool) -> Void = { value in
        if once.claim() { continuation.resume(returning: value) }
      }
      Task.detached { answer(await task.value) }
      Task.detached {
        try? await Task.sleep(for: limit)
        answer(false)
      }
    }
  }

  @Test func shouldHandEachSubscriberTheCurrentStatusAndThenEveryChangeInOrder() async {
    let feed = SyncStatusFeed(.off)
    let stream = feed.stream()
    feed.publish(.syncing)
    feed.publish(.upToDate)
    feed.finish()

    var seen: [SyncStatus] = []
    for await status in stream { seen.append(status) }

    #expect(seen == [.off, .syncing, .upToDate])
  }
}

private final class Once: Sendable {
  private let claimed = Mutex(false)

  func claim() -> Bool {
    claimed.withLock { claimed in
      defer { claimed = true }
      return !claimed
    }
  }
}
