/// Exact order of canonical decimals: the reference compares `Number(value)`, which agrees wherever a double holds the value exactly.
extension DecimalText: Comparable {
  public static func < (lhs: DecimalText, rhs: DecimalText) -> Bool {
    let left = Parts(lhs.text)
    let right = Parts(rhs.text)
    guard left.negative == right.negative else { return left.negative }
    return left.negative ? right.magnitudeBelow(left) : left.magnitudeBelow(right)
  }

  private struct Parts {
    let negative: Bool
    let whole: Substring
    let fraction: Substring

    init(_ text: String) {
      negative = text.hasPrefix("-")
      let unsigned = negative ? text.dropFirst() : Substring(text)
      let point = unsigned.firstIndex(of: ".")
      whole = point.map { unsigned[..<$0] } ?? unsigned
      fraction = point.map { unsigned[unsigned.index(after: $0)...] } ?? ""
    }

    func magnitudeBelow(_ other: Parts) -> Bool {
      guard whole.count == other.whole.count else { return whole.count < other.whole.count }
      guard whole == other.whole else { return whole < other.whole }
      return fraction < other.fraction
    }
  }
}
