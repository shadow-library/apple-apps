/// JavaScript compares strings by code units; Swift's `==` and `Hashable` equate canonically equivalent strings.
struct JSString: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
  let value: String

  init(_ value: String) {
    self.value = value
  }

  init(stringLiteral value: String) {
    self.value = value
  }

  var description: String { value }

  static func == (left: JSString, right: JSString) -> Bool {
    left.value.jsEquals(right.value)
  }

  static func < (left: JSString, right: JSString) -> Bool {
    JSText.codeUnitPrecedes(left.value, right.value)
  }

  func hash(into hasher: inout Hasher) {
    for byte in value.utf8 { hasher.combine(byte) }
  }
}

extension Sequence<String> {
  /// `[...new Set(values)]`.
  func jsUnique() -> [String] {
    var seen = Set<JSString>()
    return filter { seen.insert(JSString($0)).inserted }
  }

  func jsSorted() -> [String] {
    sorted(by: JSText.codeUnitPrecedes)
  }
}

extension Array {
  func jsSlice(_ start: Int, _ end: Int? = nil) -> [Element] {
    let from = JSText.relativeIndex(start, length: count)
    let to = end.map { JSText.relativeIndex($0, length: count) } ?? count
    return from < to ? Array(self[from..<to]) : []
  }

  /// Elements the comparator ties keep their order, as in `Array.prototype.sort`.
  func jsStableSorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
    try enumerated()
      .sorted { left, right in
        if try areInIncreasingOrder(left.element, right.element) { return true }
        if try areInIncreasingOrder(right.element, left.element) { return false }
        return left.offset < right.offset
      }
      .map(\.element)
  }
}
