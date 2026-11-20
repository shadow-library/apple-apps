/// JavaScript compares strings by code units; Swift's `==` and `Hashable` equate canonically equivalent strings.
public struct JSString: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
  public let value: String

  public init(_ value: String) {
    self.value = value
  }

  public init(stringLiteral value: String) {
    self.value = value
  }

  public var description: String { value }

  public static func == (left: JSString, right: JSString) -> Bool {
    left.value.jsEquals(right.value)
  }

  public static func < (left: JSString, right: JSString) -> Bool {
    JSText.codeUnitPrecedes(left.value, right.value)
  }

  public func hash(into hasher: inout Hasher) {
    for byte in value.utf8 { hasher.combine(byte) }
  }
}

extension Sequence<String> {
  /// `[...new Set(values)]`.
  @inlinable
  public func jsUnique() -> [String] {
    var seen = Set<JSString>()
    return filter { seen.insert(JSString($0)).inserted }
  }

  @inlinable
  public func jsSorted() -> [String] {
    sorted(by: JSText.codeUnitPrecedes)
  }
}

extension Sequence {
  /// `new Map(items.map(item => [key(item), item]))` read by key: a repeated key keeps its last element.
  @inlinable
  public func jsLastByKey(_ key: (Element) -> String) -> [JSString: Element] {
    var byKey: [JSString: Element] = [:]
    for element in self { byKey[JSString(key(element))] = element }
    return byKey
  }

  /// `[...new Map(items.map(item => [key(item), item])).values()]`: a repeated key keeps its first position and its last element.
  @inlinable
  public func jsMapValues(byKey key: (Element) -> String) -> [Element] {
    var order: [JSString] = []
    var byKey: [JSString: Element] = [:]
    for element in self {
      let id = JSString(key(element))
      if byKey.updateValue(element, forKey: id) == nil { order.append(id) }
    }
    return order.compactMap { byKey[$0] }
  }
}

extension Array {
  public func jsSlice(_ start: Int, _ end: Int? = nil) -> [Element] {
    let from = JSText.relativeIndex(start, length: count)
    let to = end.map { JSText.relativeIndex($0, length: count) } ?? count
    return from < to ? Array(self[from..<to]) : []
  }

  /// Elements the comparator ties keep their order, as in `Array.prototype.sort`.
  @inlinable
  public func jsStableSorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
    try enumerated()
      .sorted { left, right in
        if try areInIncreasingOrder(left.element, right.element) { return true }
        if try areInIncreasingOrder(right.element, left.element) { return false }
        return left.offset < right.offset
      }
      .map(\.element)
  }
}
