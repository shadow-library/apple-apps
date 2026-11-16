import ShadowCore

enum OrderedJSON: Sendable {
  case null
  case bool(Bool)
  /// Keeps its exact value beyond 2^53, where JavaScript would round it.
  case int(Int64)
  case double(Double)
  case string(String)
  case array([OrderedJSON])
  case object(OrderedJSONObject)
}

struct OrderedJSONObject: Sendable {
  struct Entry: Sendable {
    let key: String
    let value: OrderedJSON
  }

  let entries: [Entry]

  init(_ pairs: [(key: String, value: OrderedJSON)]) {
    var values: [JSString: OrderedJSON] = [:]
    var insertionOrder: [String] = []
    for pair in pairs where values.updateValue(pair.value, forKey: JSString(pair.key)) == nil { insertionOrder.append(pair.key) }
    entries = JSText.ownPropertyKeyOrder(insertionOrder).compactMap { key in values[JSString(key)].map { Entry(key: key, value: $0) } }
  }

  var keys: [String] { entries.map(\.key) }

  subscript(key: String) -> OrderedJSON? {
    entries.first { $0.key.jsEquals(key) }?.value
  }
}

extension OrderedJSON {
  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var numberValue: Double? {
    switch self {
    case .int(let value): Double(value)
    case .double(let value): value
    default: nil
    }
  }

  var arrayValue: [OrderedJSON]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var objectValue: OrderedJSONObject? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  /// Lossy: canonically equivalent keys have already collapsed in the dictionary and its order is unknown, so keys come out in code-unit order.
  init(_ value: JSONValue) {
    switch value {
    case .null: self = .null
    case .bool(let flag): self = .bool(flag)
    case .int(let number): self = .int(number)
    case .string(let text): self = .string(text)
    case .array(let items): self = .array(items.map(OrderedJSON.init))
    case .object(let fields): self = .object(OrderedJSONObject(fields.keys.jsSorted().map { (key: $0, value: OrderedJSON(fields[$0] ?? .null)) }))
    }
  }
}

extension OrderedJSON: Equatable {
  static func == (left: OrderedJSON, right: OrderedJSON) -> Bool {
    switch (left, right) {
    case (.null, .null): true
    case (.bool(let a), .bool(let b)): a == b
    case (.int(let a), .int(let b)): a == b
    case (.double(let a), .double(let b)): a == b
    case (.string(let a), .string(let b)): a.jsEquals(b)
    case (.array(let a), .array(let b)): a == b
    case (.object(let a), .object(let b)): a == b
    default: false
    }
  }
}

extension OrderedJSONObject: Equatable {
  static func == (left: OrderedJSONObject, right: OrderedJSONObject) -> Bool {
    left.entries == right.entries
  }
}

extension OrderedJSONObject.Entry: Equatable {
  static func == (left: OrderedJSONObject.Entry, right: OrderedJSONObject.Entry) -> Bool {
    left.key.jsEquals(right.key) && left.value == right.value
  }
}

enum OrderedJSONParseError: ShadowError, Equatable {
  case syntax(offset: Int)
  case tooDeep(limit: Int)

  var code: String {
    switch self {
    case .syntax: "ordered-json.syntax"
    case .tooDeep: "ordered-json.too-deep"
    }
  }

  var errorDescription: String? {
    switch self {
    case .syntax(let offset): "The text is not JSON (at byte \(offset))."
    case .tooDeep(let limit): "The JSON nests deeper than \(limit) levels."
    }
  }
}

extension OrderedJSON {
  /// Containers nested deeper than this are refused, `JSON.parse` has no such limit; the value's recursive deinit and equality must fit a 512 KB thread stack in a debug build.
  static let maximumParsingDepth = 128

  /// Accepts what `JSON.parse` accepts. An integer without fraction or exponent that fits Int64 is `.int` except `-0`, which is `.double(-0.0)`; every other number is `.double`, nearest-rounded as JavaScript does.
  init(parsing text: String) throws(OrderedJSONParseError) {
    var parser = OrderedJSONParser(bytes: Array(text.utf8))
    self = try parser.parse()
  }
}

private struct OrderedJSONParser {
  private struct Frame {
    var isObject: Bool
    var items: [OrderedJSON] = []
    var pairs: [(key: String, value: OrderedJSON)] = []
    var key = ""
  }

  let bytes: [UInt8]
  private var position = 0
  private var stack: [Frame] = []

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  mutating func parse() throws(OrderedJSONParseError) -> OrderedJSON {
    var completed: OrderedJSON? = nil
    while true {
      skipWhitespace()
      let value: OrderedJSON
      if let finished = completed {
        value = finished
      } else if let started = try start() {
        value = started
      } else {
        continue
      }
      guard var frame = stack.popLast() else {
        skipWhitespace()
        guard position == bytes.count else { throw failure() }
        return value
      }
      if frame.isObject { frame.pairs.append((key: frame.key, value: value)) } else { frame.items.append(value) }
      skipWhitespace()
      switch bytes.get(position) {
      case UInt8(ascii: ","):
        position += 1
        skipWhitespace()
        if frame.isObject { frame.key = try readKey() }
        stack.append(frame)
        completed = nil
      case UInt8(ascii: "}") where frame.isObject:
        position += 1
        completed = .object(OrderedJSONObject(frame.pairs))
      case UInt8(ascii: "]") where !frame.isObject:
        position += 1
        completed = .array(frame.items)
      default:
        throw failure()
      }
    }
  }

  private func failure() -> OrderedJSONParseError {
    .syntax(offset: position)
  }

  private mutating func skipWhitespace() {
    while let byte = bytes.get(position), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { position += 1 }
  }

  private mutating func open(isObject: Bool, closing: UInt8) throws(OrderedJSONParseError) -> OrderedJSON? {
    guard stack.count < OrderedJSON.maximumParsingDepth else { throw .tooDeep(limit: OrderedJSON.maximumParsingDepth) }
    position += 1
    skipWhitespace()
    if bytes.get(position) == closing {
      position += 1
      return isObject ? .object(OrderedJSONObject([])) : .array([])
    }
    var frame = Frame(isObject: isObject)
    if isObject { frame.key = try readKey() }
    stack.append(frame)
    return nil
  }

  private mutating func start() throws(OrderedJSONParseError) -> OrderedJSON? {
    guard let byte = bytes.get(position) else { throw failure() }
    switch byte {
    case UInt8(ascii: "{"): return try open(isObject: true, closing: UInt8(ascii: "}"))
    case UInt8(ascii: "["): return try open(isObject: false, closing: UInt8(ascii: "]"))
    case UInt8(ascii: "\""): return .string(try readString())
    case UInt8(ascii: "t"): return try literal("true", .bool(true))
    case UInt8(ascii: "f"): return try literal("false", .bool(false))
    case UInt8(ascii: "n"): return try literal("null", .null)
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try readNumber()
    default: throw failure()
    }
  }

  private mutating func literal(_ word: StaticString, _ value: OrderedJSON) throws(OrderedJSONParseError) -> OrderedJSON {
    let expected = Array(String(describing: word).utf8)
    guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected else { throw failure() }
    position += expected.count
    return value
  }

  private mutating func readKey() throws(OrderedJSONParseError) -> String {
    guard bytes.get(position) == UInt8(ascii: "\"") else { throw failure() }
    let key = try readString()
    skipWhitespace()
    guard bytes.get(position) == UInt8(ascii: ":") else { throw failure() }
    position += 1
    skipWhitespace()
    return key
  }

  private mutating func readString() throws(OrderedJSONParseError) -> String {
    position += 1
    var units: [UInt16] = []
    var runStart = position
    func flush(upTo end: Int, _ units: inout [UInt16]) {
      if end > runStart { units.append(contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).utf16) }
    }
    while let byte = bytes.get(position) {
      switch byte {
      case UInt8(ascii: "\""):
        flush(upTo: position, &units)
        position += 1
        return JSText.string(fromCodeUnits: units)
      case 0x00..<0x20:
        throw failure()
      case UInt8(ascii: "\\"):
        flush(upTo: position, &units)
        position += 1
        units.append(try readEscape())
        runStart = position
      default:
        position += 1
      }
    }
    throw failure()
  }

  private mutating func readEscape() throws(OrderedJSONParseError) -> UInt16 {
    guard let byte = bytes.get(position) else { throw failure() }
    position += 1
    switch byte {
    case UInt8(ascii: "\""): return 0x22
    case UInt8(ascii: "\\"): return 0x5C
    case UInt8(ascii: "/"): return 0x2F
    case UInt8(ascii: "b"): return 0x08
    case UInt8(ascii: "f"): return 0x0C
    case UInt8(ascii: "n"): return 0x0A
    case UInt8(ascii: "r"): return 0x0D
    case UInt8(ascii: "t"): return 0x09
    case UInt8(ascii: "u"):
      var unit: UInt16 = 0
      for _ in 0..<4 {
        guard let digit = bytes.get(position).flatMap(hexValue) else { throw failure() }
        unit = unit << 4 | digit
        position += 1
      }
      return unit
    default:
      position -= 1
      throw failure()
    }
  }

  private func hexValue(_ byte: UInt8) -> UInt16? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt16(byte - UInt8(ascii: "0"))
    case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt16(byte - UInt8(ascii: "a") + 10)
    case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt16(byte - UInt8(ascii: "A") + 10)
    default: nil
    }
  }

  private mutating func skipDigits() -> Int {
    let begin = position
    while let byte = bytes.get(position), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { position += 1 }
    return position - begin
  }

  private mutating func readNumber() throws(OrderedJSONParseError) -> OrderedJSON {
    let begin = position
    if bytes.get(position) == UInt8(ascii: "-") { position += 1 }
    guard let first = bytes.get(position) else { throw failure() }
    switch first {
    case UInt8(ascii: "0"): position += 1
    case UInt8(ascii: "1")...UInt8(ascii: "9"): _ = skipDigits()
    default: throw failure()
    }
    var isInteger = true
    if bytes.get(position) == UInt8(ascii: ".") {
      isInteger = false
      position += 1
      guard skipDigits() > 0 else { throw failure() }
    }
    if let marker = bytes.get(position), marker == UInt8(ascii: "e") || marker == UInt8(ascii: "E") {
      isInteger = false
      position += 1
      if let sign = bytes.get(position), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { position += 1 }
      guard skipDigits() > 0 else { throw failure() }
    }
    let text = String(decoding: bytes[begin..<position], as: UTF8.self)
    if isInteger, text != "-0", let integer = Int64(text) { return .int(integer) }
    guard let number = Double(text) else { throw failure() }
    return .double(number)
  }
}

extension Array {
  fileprivate func get(_ index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
