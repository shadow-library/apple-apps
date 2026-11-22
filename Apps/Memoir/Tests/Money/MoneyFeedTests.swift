import Foundation
import ShadowAppShell
import Testing

@testable import Memoir

@MainActor
@Suite("MoneyFeed", TestTimeLimit.quick)
struct MoneyFeedTests {
  @Test("should take values only from the stream it follows last")
  func dropsAReplacedStream() async throws {
    let feed = MoneyFeed<Int>()
    let (first, firstInput) = AsyncThrowingStream<Int, any Error>.makeStream()
    let (second, secondInput) = AsyncThrowingStream<Int, any Error>.makeStream()
    feed.follow { first }
    firstInput.yield(1)
    try await TestClock.until("the first value") { feed.state.value == 1 }

    feed.follow { second }
    firstInput.yield(2)
    secondInput.yield(3)
    try await TestClock.until("the second stream's value") { feed.state.value == 3 }
    firstInput.yield(4)
    firstInput.finish(throwing: CancellationError())
    try await Task.sleep(for: .milliseconds(50))
    #expect(feed.state.value == 3)

    feed.stop()
    secondInput.yield(5)
    try await Task.sleep(for: .milliseconds(50))
    #expect(feed.state.value == 3, "a stopped feed takes nothing more")
  }

  @Test("should show a failure of the stream it follows and load again when it follows another")
  func showsFailures() async throws {
    let feed = MoneyFeed<Int>()
    struct Broken: Error {}
    let (failing, failingInput) = AsyncThrowingStream<Int, any Error>.makeStream()
    feed.follow { failing }
    failingInput.finish(throwing: Broken())
    try await TestClock.until("the failure") { if case .failed = feed.state { true } else { false } }

    let (working, workingInput) = AsyncThrowingStream<Int, any Error>.makeStream()
    feed.follow { working }
    #expect(feed.state == .loading)
    workingInput.yield(7)
    try await TestClock.until("the value") { feed.state.value == 7 }
  }
}
