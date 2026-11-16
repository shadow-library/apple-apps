/// The code units a match can go on with at a position: the next unit, or the previous one when matching backward, and whether the input may end there.
/// It is only a necessary condition, so a choice whose need refuses the input could only fail, and the matcher skips it without trying it.
struct JSRegexNeed: Sendable, Equatable {
  static let anything = JSRegexNeed(asciiLow: ~0, asciiHigh: ~0, others: nil, boundary: true)
  static let nothing = JSRegexNeed(asciiLow: 0, asciiHigh: 0, others: [], boundary: false)
  static let boundary = JSRegexNeed(asciiLow: 0, asciiHigh: 0, others: [], boundary: true)

  private(set) var asciiLow: UInt64
  private(set) var asciiHigh: UInt64
  /// The units from U+0080 up; nil admits every one of them.
  private(set) var others: Set<UInt16>?
  private(set) var boundary: Bool

  init(asciiLow: UInt64, asciiHigh: UInt64, others: Set<UInt16>?, boundary: Bool) {
    self.asciiLow = asciiLow
    self.asciiHigh = asciiHigh
    self.others = others
    self.boundary = boundary
  }

  init(units: some Sequence<UInt16>) {
    self = .nothing
    for unit in units {
      switch unit {
      case 0..<64: asciiLow |= 1 << UInt64(unit)
      case 64..<128: asciiHigh |= 1 << UInt64(unit - 64)
      default: others?.insert(unit)
      }
    }
  }

  func union(_ other: JSRegexNeed) -> JSRegexNeed {
    let others: Set<UInt16>? =
      switch (self.others, other.others) {
      case (let mine?, let theirs?): mine.union(theirs)
      default: nil
      }
    return JSRegexNeed(asciiLow: asciiLow | other.asciiLow, asciiHigh: asciiHigh | other.asciiHigh, others: others, boundary: boundary || other.boundary)
  }

  func intersection(_ other: JSRegexNeed) -> JSRegexNeed {
    let others: Set<UInt16>? =
      switch (self.others, other.others) {
      case (let mine?, let theirs?): mine.intersection(theirs)
      case (let only?, nil), (nil, let only?): only
      case (nil, nil): nil
      }
    return JSRegexNeed(asciiLow: asciiLow & other.asciiLow, asciiHigh: asciiHigh & other.asciiHigh, others: others, boundary: boundary && other.boundary)
  }

  /// Whether some code unit is admitted by both; the boundary does not count.
  func overlaps(_ other: JSRegexNeed) -> Bool {
    if asciiLow & other.asciiLow != 0 || asciiHigh & other.asciiHigh != 0 { return true }
    switch (others, other.others) {
    case (let mine?, let theirs?): return !mine.isDisjoint(with: theirs)
    case (let only?, nil), (nil, let only?): return !only.isEmpty
    case (nil, nil): return true
    }
  }

  func admits(_ unit: UInt16) -> Bool {
    if unit < 64 { return asciiLow >> UInt64(unit) & 1 == 1 }
    if unit < 128 { return asciiHigh >> UInt64(unit - 64) & 1 == 1 }
    return others?.contains(unit) ?? true
  }

  func admits(_ units: [UInt16], at position: Int, _ direction: JSRegexDirection) -> Bool {
    switch direction {
    case .forward: position < units.count ? admits(units[position]) : boundary
    case .backward: position > 0 ? admits(units[position - 1]) : boundary
    }
  }
}

/// How a pattern node passes a need on: the need before it is `consumed ∪ (passed ∩ after)`, where `after` is the need of what follows it.
struct JSRegexFlow: Sendable {
  static let transparent = JSRegexFlow(consumed: .nothing, passed: .anything)
  static let impossible = JSRegexFlow(consumed: .nothing, passed: .nothing)

  let consumed: JSRegexNeed
  let passed: JSRegexNeed

  func need(before after: JSRegexNeed) -> JSRegexNeed {
    consumed.union(passed.intersection(after))
  }

  func then(_ next: JSRegexFlow) -> JSRegexFlow {
    JSRegexFlow(consumed: need(before: next.consumed), passed: passed.intersection(next.passed))
  }

  func union(_ other: JSRegexFlow) -> JSRegexFlow {
    JSRegexFlow(consumed: consumed.union(other.consumed), passed: passed.union(other.passed))
  }
}

/// A need checked at run time, in the direction of the pattern part it guards.
struct JSRegexGuard: Sendable {
  let need: JSRegexNeed
  let direction: JSRegexDirection

  func admits(_ units: [UInt16], at position: Int) -> Bool {
    need.admits(units, at: position, direction)
  }
}

/// The alternatives of one disjunction, with each one's need folded into a bit mask per unit, so a position tries only those that can go on.
struct JSRegexAlternation: Sendable {
  static let capacity = UInt64.bitWidth

  let entries: [Int]
  let direction: JSRegexDirection
  private let asciiMasks: [UInt64]
  private let boundaryMask: UInt64
  private let openMask: UInt64
  private let otherMasks: [UInt16: UInt64]

  init(entries: [Int], needs: [JSRegexNeed], _ direction: JSRegexDirection) {
    self.entries = entries
    self.direction = direction
    var asciiMasks = Array(repeating: UInt64(0), count: 128)
    var boundaryMask: UInt64 = 0
    var openMask: UInt64 = 0
    var otherMasks: [UInt16: UInt64] = [:]
    for (offset, need) in needs.enumerated() {
      let bit = UInt64(1) << UInt64(offset)
      for unit in UInt16(0)..<128 where need.admits(unit) { asciiMasks[Int(unit)] |= bit }
      if need.boundary { boundaryMask |= bit }
      guard let others = need.others else {
        openMask |= bit
        continue
      }
      for unit in others { otherMasks[unit, default: 0] |= bit }
    }
    self.asciiMasks = asciiMasks
    self.boundaryMask = boundaryMask
    self.openMask = openMask
    self.otherMasks = otherMasks
  }

  /// Bit `n` is set when alternative `n` can go on at `position`.
  func candidates(in units: [UInt16], at position: Int) -> UInt64 {
    let unit: UInt16
    switch direction {
    case .forward:
      guard position < units.count else { return boundaryMask }
      unit = units[position]
    case .backward:
      guard position > 0 else { return boundaryMask }
      unit = units[position - 1]
    }
    if unit < 128 { return asciiMasks[Int(unit)] }
    return openMask | (otherMasks[unit] ?? 0)
  }
}
