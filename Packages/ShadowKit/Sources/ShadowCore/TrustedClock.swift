import Foundation
import Synchronization

public protocol MonotonicTimeSource: Sendable {
  func nanoseconds() -> UInt64
}

public struct SystemMonotonicTimeSource: MonotonicTimeSource {
  private let origin = ContinuousClock.now

  public init() {}

  public func nanoseconds() -> UInt64 {
    let components = origin.duration(to: ContinuousClock.now).components
    let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    return UInt64(max(nanoseconds, 0))
  }
}

public enum TrustedTime: Sendable, Equatable {
  case estimate(Date)
  case lowerBound(Date)
  case unavailable
}

public struct TrustedClockSnapshot: Sendable, Codable, Equatable {
  public let serverDate: Date

  public init(serverDate: Date) {
    self.serverDate = serverDate
  }
}

public final class TrustedClock: Sendable {
  private struct Sample {
    let serverDate: Date
    let reading: UInt64
  }

  private struct State {
    var samples: [Sample] = []
    var restored: Date?
  }

  private static let maxSamples = 5

  private let wallClock: @Sendable () -> Date
  private let monotonic: any MonotonicTimeSource
  private let state: Mutex<State>

  public init(wallClock: @escaping @Sendable () -> Date = { Date() }, monotonic: any MonotonicTimeSource = SystemMonotonicTimeSource(), restored: TrustedClockSnapshot? = nil) {
    self.wallClock = wallClock
    self.monotonic = monotonic
    state = Mutex(State(restored: restored?.serverDate))
  }

  public func record(serverDate: Date) {
    state.withLock { state in
      let reading = monotonic.nanoseconds()
      state.samples.removeAll { $0.reading > reading }
      state.samples.append(Sample(serverDate: serverDate, reading: reading))
      if state.samples.count > Self.maxSamples { state.samples.removeFirst(state.samples.count - Self.maxSamples) }
    }
  }

  public func record(httpDateHeader: String) {
    guard let date = Self.parseHTTPDate(httpDateHeader) else { return }
    record(serverDate: date)
  }

  public func now() -> TrustedTime {
    state.withLock { state in
      let reading = monotonic.nanoseconds()
      state.samples.removeAll { $0.reading > reading }
      guard !state.samples.isEmpty else { return state.restored.map { .lowerBound($0) } ?? .unavailable }
      let candidates = state.samples.map { $0.serverDate.timeIntervalSinceReferenceDate + Double(reading - $0.reading) / 1_000_000_000 }.sorted()
      let middle = candidates.count / 2
      let median = candidates.count % 2 == 1 ? candidates[middle] : (candidates[middle - 1] + candidates[middle]) / 2
      return .estimate(Date(timeIntervalSinceReferenceDate: median))
    }
  }

  var sampleCount: Int { state.withLock { $0.samples.count } }

  public var snapshot: TrustedClockSnapshot? {
    switch now() {
    case .estimate(let date), .lowerBound(let date): TrustedClockSnapshot(serverDate: date)
    case .unavailable: nil
    }
  }

  public func deviceClockSkew() -> Duration? {
    guard case .estimate(let estimate) = now() else { return nil }
    return .seconds(wallClock().timeIntervalSince(estimate))
  }

  public func isDeviceClockWrong(tolerance: Duration = .seconds(300)) -> Bool? {
    guard let skew = deviceClockSkew() else { return nil }
    return abs(skew.seconds) > tolerance.seconds
  }

  public func isTooFarAhead(_ date: Date, tolerance: Duration = .seconds(86_400)) -> Bool? {
    guard case .estimate(let estimate) = now() else { return nil }
    return date.timeIntervalSince(estimate) > tolerance.seconds
  }

  public static func parseHTTPDate(_ value: String) -> Date? {
    HTTPDate.parse(value, referenceYear: HTTPDate.currentYear(at: Date()))
  }
}

extension Duration {
  fileprivate var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
