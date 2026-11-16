public struct TokenUsage: Sendable, Equatable, Codable {
  public var input: Int
  public var output: Int
  public var cacheRead: Int
  public var cacheWriteShort: Int
  public var cacheWriteLong: Int

  public static let zero = TokenUsage()

  public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWriteShort: Int = 0, cacheWriteLong: Int = 0) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWriteShort = cacheWriteShort
    self.cacheWriteLong = cacheWriteLong
  }

  public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
    TokenUsage(
      input: lhs.input + rhs.input,
      output: lhs.output + rhs.output,
      cacheRead: lhs.cacheRead + rhs.cacheRead,
      cacheWriteShort: lhs.cacheWriteShort + rhs.cacheWriteShort,
      cacheWriteLong: lhs.cacheWriteLong + rhs.cacheWriteLong
    )
  }
}

/// An amount in billionths of a US dollar; encodes as a bare integer.
public struct Cost: Sendable, Hashable, Comparable, Codable, AdditiveArithmetic {
  public static let nanoUSDPerUSD: Int64 = 1_000_000_000
  public static let zero = Cost(nanoUSD: 0)

  public let nanoUSD: Int64

  public init(nanoUSD: Int64) {
    self.nanoUSD = nanoUSD
  }

  public init(from decoder: any Decoder) throws {
    nanoUSD = try decoder.singleValueContainer().decode(Int64.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(nanoUSD)
  }

  public static func + (lhs: Cost, rhs: Cost) -> Cost { Cost(nanoUSD: lhs.nanoUSD + rhs.nanoUSD) }

  public static func - (lhs: Cost, rhs: Cost) -> Cost { Cost(nanoUSD: lhs.nanoUSD - rhs.nanoUSD) }

  public static func < (lhs: Cost, rhs: Cost) -> Bool { lhs.nanoUSD < rhs.nanoUSD }
}
