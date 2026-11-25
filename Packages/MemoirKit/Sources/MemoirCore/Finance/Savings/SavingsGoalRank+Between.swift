extension SavingsGoalRank {
  static let digits: [UInt8] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

  /// The shortest rank strictly between `lower` and `upper`, a missing bound being open: below every rank, above every rank, or the middle digit with
  /// neither. Nil when `lower` is not below `upper`, or the rank would be longer than `maximumLength`, which never happens while both are shorter than it.
  public static func between(_ lower: SavingsGoalRank?, _ upper: SavingsGoalRank?) -> SavingsGoalRank? {
    if let lower, let upper, !(lower < upper) { return nil }
    let middle = midpoint(Array((lower?.text ?? "").utf8)[...], upper.map { Array($0.text.utf8)[...] })
    return SavingsGoalRank(String(decoding: middle, as: UTF8.self))
  }

  /// `count` ranks spread evenly over the single digits, in order; nil past what one digit can hold.
  static func spread(_ count: Int) -> [SavingsGoalRank]? {
    guard count < digits.count else { return nil }
    return (0..<count).compactMap { index in SavingsGoalRank(String(decoding: [digits[(index + 1) * digits.count / (count + 1)]], as: UTF8.self)) }
  }

  /// A digit missing from `lower` reads as the lowest digit and one missing from `upper` as one past the highest, so the result never ends in the lowest
  /// digit and always sorts strictly between.
  private static func midpoint(_ lower: ArraySlice<UInt8>, _ upper: ArraySlice<UInt8>?) -> [UInt8] {
    if let upper {
      var shared = 0
      while shared < upper.count, (lower.dropFirst(shared).first ?? digits[0]) == upper[upper.startIndex + shared] { shared += 1 }
      if shared > 0 { return Array(upper.prefix(shared)) + midpoint(lower.dropFirst(shared), upper.dropFirst(shared)) }
    }
    let low = lower.first.map(value(of:)) ?? 0
    let high = upper?.first.map(value(of:)) ?? digits.count
    if high - low > 1 { return [digits[(low + high + 1) / 2]] }
    if let upper, upper.count > 1 { return [upper[upper.startIndex]] }
    return [digits[low]] + midpoint(lower.dropFirst(), nil)
  }

  private static func value(of digit: UInt8) -> Int {
    digits.firstIndex(of: digit) ?? 0
  }
}
