import Foundation

public enum StructuredExtraction {
  private enum ScanState {
    case idle
    case collecting(start: Int, closers: [UInt8])
    case skipping(depth: Int)
  }

  private static let fence = Array("```".utf8)

  /// The first JSON value in loose model text: the whole text, else a fenced block, else the first balanced object or array that parses; nil rather than a guess.
  public static func json(in text: String) -> Data? {
    let bytes = Array(text.utf8)
    guard let first = candidates(in: bytes).first else { return nil }
    return Data(bytes[first.range])
  }

  /// Every value `json(in:)` would consider, in the order it considers them, without duplicates. Linear in the length of the text.
  static func candidates(in bytes: [UInt8]) -> [StructuredJSONValue] {
    scan(bytes).candidates
  }

  /// `parses` counts the spans handed to the parser, the work that would grow with the text if the scan re-parsed what it has passed.
  static func scan(_ bytes: [UInt8]) -> (candidates: [StructuredJSONValue], parses: Int) {
    var seen = Set<Range<Int>>()
    var found: [StructuredJSONValue] = []
    var parses = 0
    func keep(_ value: StructuredJSONValue?) {
      parses += 1
      guard let value, seen.insert(value.range).inserted else { return }
      found.append(value)
    }
    keep(parsed(bytes, trimming: bytes.indices))
    for body in fencedBodies(in: bytes) { keep(parsed(bytes, trimming: body)) }
    for value in balancedValues(in: bytes) { keep(value) }
    return (found, parses)
  }

  private static func parsed(_ bytes: [UInt8], trimming range: Range<Int>) -> StructuredJSONValue? {
    var lower = range.lowerBound
    var upper = range.upperBound
    while lower < upper, StructuredJSONParser.isWhitespace(bytes[lower]) { lower += 1 }
    while upper > lower, StructuredJSONParser.isWhitespace(bytes[upper - 1]) { upper -= 1 }
    guard lower < upper else { return nil }
    return try? StructuredJSONParser.parse(bytes, in: lower..<upper)
  }

  private static func fencedBodies(in bytes: [UInt8]) -> [Range<Int>] {
    var markers: [Int] = []
    var index = 0
    while index + fence.count <= bytes.count {
      if bytes[index] == fence[0], bytes[index + 1] == fence[1], bytes[index + 2] == fence[2] {
        markers.append(index)
        index += fence.count
        while index < bytes.count, bytes[index] == fence[0] { index += 1 }
      } else {
        index += 1
      }
    }
    var bodies: [Range<Int>] = []
    var pair = 0
    while pair + 1 < markers.count {
      var start = markers[pair] + fence.count
      while start < markers[pair + 1], bytes[start] == fence[0] { start += 1 }
      let end = markers[pair + 1]
      if let newline = bytes[start..<end].firstIndex(of: 0x0A) { start = newline + 1 }
      bodies.append(start..<end)
      pair += 2
    }
    return bodies
  }

  /// Quotes outside a value are ignored, as the reference does: prose quotes are not reliably balanced, quotes inside a value are.
  private static func balancedValues(in bytes: [UInt8]) -> [StructuredJSONValue?] {
    var values: [StructuredJSONValue?] = []
    var state = ScanState.idle
    var inString = false
    var escaped = false
    for (index, byte) in bytes.enumerated() {
      if inString {
        if escaped {
          escaped = false
        } else if byte == UInt8(ascii: "\\") {
          escaped = true
        } else if byte == UInt8(ascii: "\"") {
          inString = false
        }
        continue
      }
      switch (state, byte) {
      case (.idle, UInt8(ascii: "{")), (.idle, UInt8(ascii: "[")):
        state = .collecting(start: index, closers: [closer(of: byte)])
      case (.idle, _):
        continue
      case (.collecting, UInt8(ascii: "\"")), (.skipping, UInt8(ascii: "\"")):
        inString = true
      case (.collecting(let start, var closers), UInt8(ascii: "{")), (.collecting(let start, var closers), UInt8(ascii: "[")):
        guard closers.count < StructuredJSONParser.maximumDepth else {
          state = .skipping(depth: closers.count + 1)
          continue
        }
        closers.append(closer(of: byte))
        state = .collecting(start: start, closers: closers)
      case (.collecting(let start, var closers), UInt8(ascii: "}")), (.collecting(let start, var closers), UInt8(ascii: "]")):
        guard closers.removeLast() == byte else {
          state = .idle
          continue
        }
        guard closers.isEmpty else {
          state = .collecting(start: start, closers: closers)
          continue
        }
        state = .idle
        values.append(try? StructuredJSONParser.parse(bytes, in: start..<index + 1))
      case (.skipping(let depth), UInt8(ascii: "{")), (.skipping(let depth), UInt8(ascii: "[")):
        state = .skipping(depth: depth + 1)
      case (.skipping(let depth), UInt8(ascii: "}")), (.skipping(let depth), UInt8(ascii: "]")):
        state = depth > 1 ? .skipping(depth: depth - 1) : .idle
      case (.collecting, _), (.skipping, _):
        continue
      }
    }
    return values
  }

  private static func closer(of opener: UInt8) -> UInt8 {
    opener == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
  }
}
