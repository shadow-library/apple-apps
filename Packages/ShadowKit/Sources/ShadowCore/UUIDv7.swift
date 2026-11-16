import Foundation
import Synchronization

private let maxMilliseconds: UInt64 = (1 << 48) - 1
private let tailBits: UInt128 = 74
private let tailMask: UInt128 = (1 << tailBits) - 1
private let lowTailMask: UInt64 = (1 << 62) - 1

extension UUID {
  public static func v7<G: RandomNumberGenerator>(at date: Date = Date(), using generator: inout G) -> UUID {
    make(milliseconds: milliseconds(of: date), tail: randomTail(using: &generator))
  }

  public static func v7(at date: Date = Date()) -> UUID {
    var generator = SystemRandomNumberGenerator()
    return v7(at: date, using: &generator)
  }

  public var v7Timestamp: Date? {
    let bytes = withUnsafeBytes(of: uuid) { Array($0) }
    guard bytes[6] >> 4 == 0x7, bytes[8] >> 6 == 0b10 else { return nil }
    let milliseconds = bytes[0..<6].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  public var lowercasedString: String {
    uuidString.lowercased()
  }

  static func milliseconds(of date: Date) -> UInt64 {
    let value = (date.timeIntervalSince1970 * 1000).rounded()
    guard value > 0 else { return 0 }
    guard value < Double(maxMilliseconds) else { return maxMilliseconds }
    return UInt64(value)
  }

  static func randomTail<G: RandomNumberGenerator>(using generator: inout G) -> UInt128 {
    let high = UInt128(generator.next() & 0xFFF)
    let low = UInt128(generator.next() & lowTailMask)
    return (high << 62) | low
  }

  static func make(milliseconds: UInt64, tail: UInt128) -> UUID {
    let randomA = UInt16(truncatingIfNeeded: tail >> 62)
    let randomB = UInt64(truncatingIfNeeded: tail) & lowTailMask
    return UUID(
      uuid: (
        UInt8(truncatingIfNeeded: milliseconds >> 40), UInt8(truncatingIfNeeded: milliseconds >> 32),
        UInt8(truncatingIfNeeded: milliseconds >> 24), UInt8(truncatingIfNeeded: milliseconds >> 16),
        UInt8(truncatingIfNeeded: milliseconds >> 8), UInt8(truncatingIfNeeded: milliseconds),
        0x70 | UInt8(truncatingIfNeeded: randomA >> 8), UInt8(truncatingIfNeeded: randomA),
        0x80 | UInt8(truncatingIfNeeded: randomB >> 56), UInt8(truncatingIfNeeded: randomB >> 48),
        UInt8(truncatingIfNeeded: randomB >> 40), UInt8(truncatingIfNeeded: randomB >> 32),
        UInt8(truncatingIfNeeded: randomB >> 24), UInt8(truncatingIfNeeded: randomB >> 16),
        UInt8(truncatingIfNeeded: randomB >> 8), UInt8(truncatingIfNeeded: randomB)
      ))
  }
}

public final class UUIDv7Generator: Sendable {
  private struct State {
    var milliseconds: UInt64
    var tail: UInt128
    var generator = SystemRandomNumberGenerator()
  }

  private let wallClock: @Sendable () -> Date
  private let state: Mutex<State>

  public init(wallClock: @escaping @Sendable () -> Date = { Date() }) {
    self.wallClock = wallClock
    state = Mutex(State(milliseconds: 0, tail: 0))
  }

  init(wallClock: @escaping @Sendable () -> Date, lastMilliseconds: UInt64, lastTail: UInt128) {
    self.wallClock = wallClock
    state = Mutex(State(milliseconds: lastMilliseconds, tail: lastTail & tailMask))
  }

  public func next() -> UUID {
    let now = UUID.milliseconds(of: wallClock())
    return state.withLock { state in
      if now > state.milliseconds || (state.milliseconds == 0 && state.tail == 0) {
        state.milliseconds = now
        state.tail = UUID.randomTail(using: &state.generator)
      } else if state.tail == tailMask {
        state.milliseconds = min(state.milliseconds + 1, UInt64((1 << 48) - 1))
        state.tail = 0
      } else {
        state.tail += 1
      }
      return UUID.make(milliseconds: state.milliseconds, tail: state.tail)
    }
  }
}
