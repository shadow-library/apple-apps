enum JSOffsetRounding {
  case down
  case up
}

extension String {
  public var jsLength: Int { utf16.count }

  public var jsCodeUnits: [UInt16] { Array(utf16) }

  /// `[...text]` iterates code points, not grapheme clusters.
  public var jsCodePoints: [String] { unicodeScalars.map { String($0) } }

  public func jsEquals(_ other: String) -> Bool {
    utf8.elementsEqual(other.utf8)
  }

  func jsCharCodeAt(_ index: Int) -> UInt16? {
    guard index >= 0, index < jsLength else { return nil }
    return utf16[utf16.index(utf16.startIndex, offsetBy: index)]
  }

  public func jsCharAt(_ index: Int) -> String {
    jsCharCodeAt(index).map { JSText.string(fromCodeUnits: [$0]) } ?? ""
  }

  /// An offset inside a surrogate pair rounds to the side `rounding` names.
  func jsIndex(utf16Offset offset: Int, rounding: JSOffsetRounding) -> String.Index {
    let index = utf16.index(utf16.startIndex, offsetBy: JSText.clamped(offset, length: jsLength))
    if index.samePosition(in: unicodeScalars) != nil { return index }
    return rounding == .down ? utf16.index(before: index) : utf16.index(after: index)
  }

  func jsUTF16Offset(of index: String.Index) -> Int {
    utf16.distance(from: utf16.startIndex, to: index)
  }

  public func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
    let length = jsLength
    return scalarAligned(from: JSText.relativeIndex(start, length: length), to: end.map { JSText.relativeIndex($0, length: length) } ?? length)
  }

  public func jsSliceCodeUnits(_ start: Int, _ end: Int? = nil) -> [UInt16] {
    let units = jsCodeUnits
    let from = JSText.relativeIndex(start, length: units.count)
    let to = end.map { JSText.relativeIndex($0, length: units.count) } ?? units.count
    return from < to ? Array(units[from..<to]) : []
  }

  public func jsIndexOf(_ search: String, _ position: Int = 0) -> Int {
    let units = jsCodeUnits
    return JSText.indexOf(search.jsCodeUnits, in: units, from: JSText.clamped(position, length: units.count))
  }

  public func jsIncludes(_ search: String, _ position: Int = 0) -> Bool {
    jsIndexOf(search, position) != -1
  }

  public func jsStartsWith(_ search: String, _ position: Int = 0) -> Bool {
    let units = jsCodeUnits
    let needle = search.jsCodeUnits
    let start = JSText.clamped(position, length: units.count)
    guard needle.count <= units.count - start else { return false }
    return units[start..<(start + needle.count)].elementsEqual(needle)
  }

  public func jsEndsWith(_ search: String, _ endPosition: Int? = nil) -> Bool {
    let units = jsCodeUnits
    let needle = search.jsCodeUnits
    let end = JSText.clamped(endPosition ?? units.count, length: units.count)
    guard needle.count <= end else { return false }
    return units[(end - needle.count)..<end].elementsEqual(needle)
  }

  private func scalarAligned(from start: Int, to end: Int) -> String {
    guard start < end else { return "" }
    let lower = jsIndex(utf16Offset: start, rounding: .up)
    let upper = jsIndex(utf16Offset: end, rounding: .down)
    return lower < upper ? String(unicodeScalars[lower..<upper]) : ""
  }
}
