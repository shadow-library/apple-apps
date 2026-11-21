import Foundation

/// Offsets from the moment the runtime was made, on the injected clock; the scheduler never reads the wall clock, so a clock change cannot move a deadline.
struct SyncSchedulerClock: Sendable {
  let now: @Sendable () -> Duration
  let sleep: @Sendable (_ until: Duration) async throws -> Void

  init<C: Clock>(_ clock: C) where C.Duration == Duration {
    let origin = clock.now
    now = { origin.duration(to: clock.now) }
    sleep = { deadline in try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil) }
  }
}
