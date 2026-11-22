import Foundation
import Observation
import Testing

@testable import ShadowAppShell

@MainActor
@Suite("ReadObserver", TestTimeLimit.standard)
struct ReadObserverTests {
  private func wait(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<12_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the observer")
  }

  @Test("should hand every value to the per-value hook and keep the last as the state")
  func hookSeesEveryValue() async throws {
    let observer = ReadObserver<Int>()
    let (stream, continuation) = AsyncThrowingStream<Int, any Error>.makeStream()
    var seen = [Int]()
    let task = Task { await observer.run({ stream }, onValue: { seen.append($0) }) }
    defer { task.cancel() }

    for value in [1, 1, 2] { continuation.yield(value) }

    try await wait { seen == [1, 1, 2] }
    #expect(observer.state == .loaded(2))
  }

  @Test("should not republish an equal value")
  func skipsEqualValues() async throws {
    let observer = ReadObserver<Int>()
    let (stream, continuation) = AsyncThrowingStream<Int, any Error>.makeStream()
    var seen = [Int]()
    let task = Task { await observer.run({ stream }, onValue: { seen.append($0) }) }
    defer { task.cancel() }
    continuation.yield(1)
    try await wait { seen == [1] }
    let changes = Counter()
    withObservationTracking {
      _ = observer.state
    } onChange: {
      changes.increment()
    }

    continuation.yield(1)
    try await wait { seen == [1, 1] }
    #expect(changes.value == 0)

    continuation.yield(2)
    try await wait { seen == [1, 1, 2] }
    #expect(changes.value == 1)
  }
}

private nonisolated final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func increment() { lock.withLock { count += 1 } }
}
