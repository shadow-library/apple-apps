import Foundation

public struct SeededGenerator: RandomNumberGenerator, Sendable {
  private var state: UInt64

  public init(seed: UInt64) {
    state = seed
  }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

extension SeededGenerator {
  public mutating func int(in range: ClosedRange<Int>) -> Int {
    let span = UInt64(bitPattern: Int64(range.upperBound &- range.lowerBound))
    if span == UInt64.max { return Int(bitPattern: UInt(next())) }
    let bound = span + 1
    let limit = UInt64.max - (UInt64.max % bound)
    var value = next()
    while value >= limit { value = next() }
    return range.lowerBound &+ Int(bitPattern: UInt(value % bound))
  }

  public mutating func chance(_ probability: Double) -> Bool {
    let unit = Double(next() >> 11) * 0x1p-53
    return unit < probability
  }

  public mutating func pick<C: Collection>(from collection: C) -> C.Element {
    precondition(!collection.isEmpty, "cannot pick from an empty collection")
    let offset = int(in: 0...(collection.count - 1))
    return collection[collection.index(collection.startIndex, offsetBy: offset)]
  }

  public mutating func shuffled<S: Sequence>(_ sequence: S) -> [S.Element] {
    var result = Array(sequence)
    guard result.count > 1 else { return result }
    for index in stride(from: result.count - 1, to: 0, by: -1) {
      result.swapAt(index, int(in: 0...index))
    }
    return result
  }

  public mutating func data(count: Int) -> Data {
    Data((0..<max(count, 0)).map { _ in UInt8(truncatingIfNeeded: next()) })
  }

  public mutating func asciiString(maxLength: Int) -> String {
    let length = int(in: 0...max(maxLength, 0))
    return String((0..<length).map { _ in Character(Unicode.Scalar(UInt8(int(in: 0x20...0x7E)))) })
  }

  public mutating func unicodeString(maxLength: Int) -> String {
    let length = int(in: 0...max(maxLength, 0))
    var scalars = String.UnicodeScalarView()
    for _ in 0..<length { scalars.append(unicodeScalar()) }
    return String(scalars)
  }

  private mutating func unicodeScalar() -> Unicode.Scalar {
    let value: UInt32
    switch int(in: 0...5) {
    case 0: value = UInt32(int(in: 0x00...0x1F))
    case 1: value = UInt32(pick(from: [0x22, 0x27, 0x5C, 0x7F, 0x2028, 0xFEFF] as [Int]))
    case 2: value = UInt32(int(in: 0x20...0x7E))
    case 3: value = UInt32(int(in: 0x80...0xD7FF))
    case 4: value = UInt32(int(in: 0xE000...0xFFFD))
    default: value = UInt32(int(in: 0x1_0000...0x10_FFFF))
    }
    return Unicode.Scalar(value) ?? "\u{FFFD}"
  }
}

public struct PropertyFailure: Error, CustomStringConvertible, Sendable {
  public let seed: UInt64
  public let iteration: Int
  public let underlying: String

  public var description: String {
    "property failed at iteration \(iteration) (replay seed 0x\(String(seed, radix: 16, uppercase: true))): \(underlying)"
  }
}

private func caseSeed(base: UInt64, iteration: Int) -> UInt64 {
  var mixer = SeededGenerator(seed: base &+ UInt64(truncatingIfNeeded: iteration) &* 0xD1B5_4A32_D192_ED03)
  return mixer.next()
}

public func forAll(iterations: Int = 200, seed: UInt64 = 0x5EED, _ property: (inout SeededGenerator) throws -> Void) throws(PropertyFailure) {
  for iteration in 0..<max(iterations, 0) {
    let derived = caseSeed(base: seed, iteration: iteration)
    var generator = SeededGenerator(seed: derived)
    do {
      try property(&generator)
    } catch {
      throw PropertyFailure(seed: derived, iteration: iteration, underlying: String(describing: error))
    }
  }
}

public func forAll(iterations: Int = 200, seed: UInt64 = 0x5EED, _ property: (inout SeededGenerator) async throws -> Void) async throws(PropertyFailure) {
  for iteration in 0..<max(iterations, 0) {
    let derived = caseSeed(base: seed, iteration: iteration)
    var generator = SeededGenerator(seed: derived)
    do {
      try await property(&generator)
    } catch {
      throw PropertyFailure(seed: derived, iteration: iteration, underlying: String(describing: error))
    }
  }
}

public func replay(seed: UInt64, _ property: (inout SeededGenerator) throws -> Void) throws(PropertyFailure) {
  var generator = SeededGenerator(seed: seed)
  do {
    try property(&generator)
  } catch {
    throw PropertyFailure(seed: seed, iteration: 0, underlying: String(describing: error))
  }
}

public func replay(seed: UInt64, _ property: (inout SeededGenerator) async throws -> Void) async throws(PropertyFailure) {
  var generator = SeededGenerator(seed: seed)
  do {
    try await property(&generator)
  } catch {
    throw PropertyFailure(seed: seed, iteration: 0, underlying: String(describing: error))
  }
}
