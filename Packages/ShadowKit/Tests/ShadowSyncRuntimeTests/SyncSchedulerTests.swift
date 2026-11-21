import Foundation
import Testing

@testable import ShadowSyncRuntime

@Suite("SyncScheduler", TestTimeLimit.quick)
struct SyncSchedulerTests {
  private static let policy = SyncSchedulePolicy()

  private static func inFront(cadence: SyncCadence = .polling) -> SyncScheduler {
    var scheduler = SyncScheduler(policy: policy)
    scheduler.enterForeground(at: .zero)
    scheduler.setCadence(cadence, at: .zero)
    _ = scheduler.takeDue(at: .zero)
    return scheduler
  }

  @Test("should run the launch work once and then nothing until something is due")
  func launch() {
    var scheduler = SyncScheduler(policy: Self.policy)
    scheduler.request(.launch)

    #expect(scheduler.takeDue(at: .zero) == .launch)
    #expect(scheduler.takeDue(at: .zero) == nil)
    #expect(scheduler.nextDeadline() == nil)
  }

  @Test("should evaluate and sync on foreground and poll 45 seconds after each download")
  func foregroundAndPoll() {
    var scheduler = SyncScheduler(policy: Self.policy)
    scheduler.setCadence(.polling, at: .zero)
    scheduler.enterForeground(at: .zero)

    #expect(scheduler.takeDue(at: .zero) == .foreground)
    scheduler.finish(.completed, performed: .foreground, at: .seconds(1))
    #expect(scheduler.nextDeadline() == .seconds(46))
    #expect(scheduler.takeDue(at: .seconds(45)) == nil)
    #expect(scheduler.takeDue(at: .seconds(46)) == .sync)
    scheduler.finish(.completed, performed: .sync, at: .seconds(47))
    #expect(scheduler.nextDeadline() == .seconds(92))
  }

  @Test("should upload two seconds after the last of several writes")
  func debouncesWrites() {
    var scheduler = Self.inFront()

    scheduler.localWrite(at: .seconds(1))
    scheduler.localWrite(at: .seconds(2))
    scheduler.localWrite(at: .milliseconds(2_500))

    #expect(scheduler.nextDeadline() == .milliseconds(4_500))
    #expect(scheduler.takeDue(at: .seconds(4)) == nil)
    #expect(scheduler.takeDue(at: .milliseconds(4_500)) == .upload)
    #expect(scheduler.takeDue(at: .seconds(5)) == nil)
  }

  @Test("should keep polling while writes keep arriving, since only a download moves the poll")
  func writesDoNotPostponePoll() {
    var scheduler = Self.inFront()
    var now = Duration.zero
    var polled = false

    while now < .seconds(60) {
      scheduler.localWrite(at: now)
      now += .milliseconds(1_900)
      if let work = scheduler.takeDue(at: now) {
        polled = polled || work.contains(.download)
        scheduler.finish(.completed, performed: work, at: now)
      }
    }

    #expect(polled)
  }

  @Test("should stop every timer in the background and upload once")
  func background() {
    var scheduler = Self.inFront(cadence: .awaitingKey)
    scheduler.finish(.failed(retry: .sync), performed: .sync, at: .seconds(1))
    scheduler.localWrite(at: .seconds(1))

    scheduler.enterBackground()

    #expect(scheduler.nextDeadline() == nil)
    #expect(scheduler.takeDue(at: .seconds(1)) == .sync)
    #expect(scheduler.takeDue(at: .seconds(600)) == nil)
    scheduler.localWrite(at: .seconds(601))
    #expect(scheduler.nextDeadline() == nil)
    #expect(scheduler.takeDue(at: .seconds(601)) == .upload)
  }

  @Test("should keep a storage-named wait in the background and time nothing")
  func backgroundKeepsRetryAfter() {
    var scheduler = Self.inFront()
    scheduler.finish(.rateLimited(retryAfter: .seconds(120), retry: .sync), performed: .sync, at: .zero)

    scheduler.enterBackground()

    #expect(scheduler.takeDue(at: .seconds(1)) == nil)
    #expect(scheduler.hasDeferredWork)
    #expect(scheduler.nextDeadline() == nil)
    #expect(scheduler.takeDue(at: .seconds(120)) == .sync)
  }

  @Test("should look for the key every 30 seconds while waiting for it")
  func keyCheck() {
    var scheduler = Self.inFront(cadence: .awaitingKey)

    #expect(scheduler.nextDeadline() == .seconds(30))
    #expect(scheduler.takeDue(at: .seconds(30)) == .launch)
    scheduler.finish(.completed, performed: .launch, at: .seconds(31))
    #expect(scheduler.nextDeadline() == .seconds(61))

    scheduler.setCadence(.polling, at: .seconds(31))
    #expect(scheduler.nextDeadline() == .seconds(76))
  }

  @Test("should hold every trigger until a storage retry-after passes, foreground included")
  func honoursRetryAfter() {
    var scheduler = Self.inFront()

    scheduler.finish(.rateLimited(retryAfter: .seconds(120), retry: .sync), performed: .sync, at: .zero)

    #expect(scheduler.nextDeadline() == .seconds(120))
    #expect(scheduler.takeDue(at: .seconds(45)) == nil)
    scheduler.enterForeground(at: .seconds(60))
    scheduler.localWrite(at: .seconds(61))
    #expect(scheduler.takeDue(at: .seconds(70)) == nil)
    #expect(scheduler.hasDeferredWork)
    #expect(scheduler.consecutiveFailures == 0)
    #expect(scheduler.takeDue(at: .seconds(120)) == .foreground)
  }

  @Test("should bound a retry-after storage names")
  func boundsRetryAfter() {
    var scheduler = Self.inFront()

    scheduler.finish(.rateLimited(retryAfter: .seconds(10 * 3_600), retry: .sync), performed: .sync, at: .zero)
    #expect(scheduler.retryAt == .seconds(3_600))

    scheduler.finish(.rateLimited(retryAfter: .seconds(-5), retry: .sync), performed: .sync, at: .seconds(3_600))
    #expect(scheduler.retryAt == .seconds(3_600))
  }

  @Test("should back off exponentially up to the cap and start again after a success")
  func backsOff() {
    var scheduler = Self.inFront()
    var delays: [Duration] = []
    var now = Duration.zero

    for _ in 0..<10 {
      scheduler.finish(.failed(retry: .sync), performed: .sync, at: now)
      let retry = scheduler.retryAt ?? now
      delays.append(retry - now)
      now = retry
      #expect(scheduler.takeDue(at: now) == .sync)
    }
    scheduler.finish(.completed, performed: .sync, at: now)
    scheduler.finish(.failed(retry: .sync), performed: .sync, at: now)

    #expect(delays == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300].map { Duration.seconds($0) })
    #expect(scheduler.retryAt == now + .seconds(2))
  }

  @Test(
    "should let a foreground skip a backoff the device chose",
    arguments: [SyncRunResult.rateLimited(retryAfter: nil, retry: .sync), .failed(retry: .sync)])
  func foregroundSkipsBackoff(failure: SyncRunResult) {
    var scheduler = Self.inFront()
    scheduler.finish(failure, performed: .sync, at: .zero)
    #expect(scheduler.takeDue(at: .seconds(1)) == nil)

    scheduler.enterForeground(at: .seconds(1))

    #expect(scheduler.takeDue(at: .seconds(1)) == .foreground)
  }

  @Test("should merge everything requested before a run into one run")
  func coalesces() {
    var scheduler = Self.inFront()
    scheduler.request(.sync)
    scheduler.request(.sync)
    scheduler.request(.evaluate)
    scheduler.localWrite(at: .zero)

    #expect(scheduler.takeDue(at: .seconds(2)) == [.evaluate, .download, .upload])
    #expect(scheduler.takeDue(at: .seconds(2)) == nil)
  }

  @Test("should compute retry delays without overflow for any failure count")
  func retryDelays() {
    let policy = SyncSchedulePolicy(firstRetryDelay: .zero)

    #expect(Self.policy.retryDelay(afterFailures: 0) == .zero)
    #expect(Self.policy.retryDelay(afterFailures: 1) == .seconds(2))
    #expect(Self.policy.retryDelay(afterFailures: .max) == .seconds(300))
    #expect(policy.retryDelay(afterFailures: 1_000) == .zero)
  }
}
