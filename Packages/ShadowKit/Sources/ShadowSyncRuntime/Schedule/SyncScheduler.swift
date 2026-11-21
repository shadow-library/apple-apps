import Foundation

enum SyncCadence: Sendable, Equatable {
  case idle
  case polling
  case awaitingKey
}

enum SyncRunResult: Sendable, Equatable {
  case completed
  case rateLimited(retryAfter: Duration?, retry: SyncWork)
  case failed(retry: SyncWork)
}

/// Decides when the runtime syncs and what each run does. Times are offsets on the runtime's monotonic clock. Requests collect until the
/// runtime takes them, so everything asked for during a run becomes one follow-up run. In the background nothing is timed: only explicit
/// requests run.
struct SyncScheduler: Sendable {
  private struct Gate: Sendable, Equatable {
    let until: Duration
    /// Set when storage named the wait; a foreground skips only a wait the device chose itself.
    let isMandated: Bool
  }

  let policy: SyncSchedulePolicy
  private(set) var isInFront = false
  private(set) var cadence = SyncCadence.idle
  private(set) var consecutiveFailures = 0
  private var requested: SyncWork = []
  private var deferred: SyncWork = []
  private var gate: Gate?
  private var uploadDue: Duration?
  private var pollDue: Duration?
  private var keyCheckDue: Duration?

  init(policy: SyncSchedulePolicy) {
    self.policy = policy
  }

  var hasDeferredWork: Bool { !deferred.isEmpty }

  var retryAt: Duration? { gate?.until }

  mutating func request(_ work: SyncWork) {
    requested.formUnion(work)
  }

  mutating func enterForeground(at now: Duration) {
    isInFront = true
    if gate?.isMandated == false { gate = nil }
    requested.formUnion(.foreground)
    pollDue = cadence == .polling ? now + policy.pollInterval : nil
    keyCheckDue = cadence == .awaitingKey ? now + policy.keyCheckInterval : nil
  }

  /// Skips a backoff the device chose, so the final upload is not lost to a failure just before; a wait storage named still holds.
  mutating func enterBackground() {
    isInFront = false
    if gate?.isMandated == false { gate = nil }
    uploadDue = nil
    pollDue = nil
    keyCheckDue = nil
    requested.insert(.upload)
  }

  mutating func localWrite(at now: Duration) {
    guard isInFront else {
      requested.insert(.upload)
      return
    }
    uploadDue = now + policy.uploadDelay
  }

  mutating func setCadence(_ cadence: SyncCadence, at now: Duration) {
    guard cadence != self.cadence else { return }
    self.cadence = cadence
    pollDue = isInFront && cadence == .polling ? now + policy.pollInterval : nil
    keyCheckDue = isInFront && cadence == .awaitingKey ? now + policy.keyCheckInterval : nil
  }

  mutating func reset() {
    requested = []
    deferred = []
    gate = nil
    consecutiveFailures = 0
    uploadDue = nil
    pollDue = nil
    keyCheckDue = nil
    cadence = .idle
  }

  /// The work due at `now`, or nil; work held back by a retry wait is kept and runs once the wait is over.
  mutating func takeDue(at now: Duration) -> SyncWork? {
    var due = requested
    requested = []
    if let uploadDue, uploadDue <= now {
      due.insert(.upload)
      self.uploadDue = nil
    }
    if let pollDue, pollDue <= now {
      due.formUnion(.sync)
      self.pollDue = nil
    }
    if let keyCheckDue, keyCheckDue <= now {
      due.formUnion(.launch)
      self.keyCheckDue = nil
    }
    if let gate, gate.until > now {
      deferred.formUnion(due)
      return nil
    }
    gate = nil
    due.formUnion(deferred)
    deferred = []
    return due.isEmpty ? nil : due
  }

  /// When the runtime should next call `takeDue(at:)`; nil in the background, where nothing is timed.
  func nextDeadline() -> Duration? {
    guard isInFront else { return nil }
    var deadlines = [uploadDue, pollDue, keyCheckDue].compactMap(\.self)
    if let gate, !deferred.isEmpty { deadlines.append(gate.until) }
    guard let earliest = deadlines.min() else { return nil }
    return max(earliest, gate?.until ?? earliest)
  }

  mutating func finish(_ result: SyncRunResult, performed: SyncWork, at now: Duration) {
    switch result {
    case .completed:
      consecutiveFailures = 0
      gate = nil
    case .rateLimited(let retryAfter?, let retry):
      gate = Gate(until: now + policy.honoured(retryAfter: retryAfter), isMandated: true)
      deferred.formUnion(retry)
    case .rateLimited(nil, let retry), .failed(let retry):
      consecutiveFailures += 1
      gate = Gate(until: now + policy.retryDelay(afterFailures: consecutiveFailures), isMandated: false)
      deferred.formUnion(retry)
    }
    guard isInFront else { return }
    if performed.contains(.download), cadence == .polling { pollDue = now + policy.pollInterval }
    if performed.contains(.evaluate), cadence == .awaitingKey { keyCheckDue = now + policy.keyCheckInterval }
  }
}
