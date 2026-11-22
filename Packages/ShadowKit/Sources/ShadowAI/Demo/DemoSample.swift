import ShadowCore

/// The simplest value a schema accepts: required properties only, the fewest items allowed (plus one for `contains`), the first `enum` value or `anyOf`
/// branch that holds, the lowest number allowed, `text` fitted to a string's length bounds, and an `if` answered by building again under the branch the
/// value first built meets.
enum DemoSample {
  static func value(for schema: JSONValue, text: String) -> JSONValue? {
    let value = make(schema, text: text, depth: 0)
    guard accepts(schema, value) else { return JSONValue?.none }
    return value
  }

  static func accepts(_ schema: JSONValue, _ value: JSONValue) -> Bool {
    StructuredSchema.validate(CanonicalJSON.encode(value), against: schema).isEmpty
  }

  private static func make(_ schema: JSONValue, text: String, depth: Int) -> JSONValue {
    guard case .object(let keywords) = schema, depth < CanonicalJSON.maximumDepth else { return .null }
    if let constant = keywords["const"] { return constant }
    if let first = keywords["enum"]?.arrayValue?.first { return first }
    if let condition = keywords["if"] {
      var base = keywords
      let branches = (then: base.removeValue(forKey: "then"), otherwise: base.removeValue(forKey: "else"))
      base["if"] = nil
      let provisional = make(.object(base), text: text, depth: depth + 1)
      guard let branch = (accepts(condition, provisional) ? branches.then : branches.otherwise)?.objectValue else { return provisional }
      return make(.object(merged(base, branch)), text: text, depth: depth + 1)
    }
    if let branches = keywords["anyOf"]?.arrayValue {
      for branch in branches {
        let candidate = make(branch, text: text, depth: depth + 1)
        if accepts(schema, candidate) { return candidate }
      }
    }
    switch typeName(keywords) {
    case "object": return object(keywords, text: text, depth: depth)
    case "array": return array(keywords, text: text, depth: depth)
    case "string": return .string(fitted(text, keywords))
    case "integer", "number": return .int(number(keywords))
    case "boolean": return .bool(false)
    default: return .null
    }
  }

  private static func typeName(_ keywords: [String: JSONValue]) -> String {
    switch keywords["type"] {
    case .string(let name): return name
    case .array(let names): return names.lazy.compactMap(\.stringValue).first { $0 != "null" } ?? "null"
    default: break
    }
    if keywords["properties"] != nil || keywords["required"] != nil { return "object" }
    if keywords["items"] != nil { return "array" }
    return "string"
  }

  private static func object(_ keywords: [String: JSONValue], text: String, depth: Int) -> JSONValue {
    let properties = keywords["properties"]?.objectValue ?? [:]
    var members: [String: JSONValue] = [:]
    for name in keywords["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
      members[name] = make(properties[name] ?? [:], text: text, depth: depth + 1)
    }
    return .object(members)
  }

  private static func array(_ keywords: [String: JSONValue], text: String, depth: Int) -> JSONValue {
    let items = keywords["items"] ?? [:]
    var elements = Array(repeating: make(items, text: text, depth: depth + 1), count: Int(clamping: keywords["minItems"]?.intValue ?? 0))
    if let wanted = keywords["contains"], !elements.contains(where: { accepts(wanted, $0) }) {
      let both = merged(items.objectValue ?? [:], wanted.objectValue ?? [:])
      elements.append(make(.object(both), text: text, depth: depth + 1))
    }
    return .array(elements)
  }

  /// `branch` laid over `base`: properties merge by name and `required` lists join; any other keyword of the branch replaces the base's.
  private static func merged(_ base: [String: JSONValue], _ branch: [String: JSONValue]) -> [String: JSONValue] {
    var result = base
    for (keyword, value) in branch {
      switch (keyword, result[keyword], value) {
      case ("properties", .object(let own)?, .object(let added)):
        result[keyword] = .object(
          own.merging(added) { mine, theirs in
            guard case .object(let mine) = mine, case .object(let theirs) = theirs else { return theirs }
            return .object(merged(mine, theirs))
          })
      case ("required", .array(let own)?, .array(let added)):
        result[keyword] = .array(own + added.filter { !own.contains($0) })
      default:
        result[keyword] = value
      }
    }
    return result
  }

  private static func fitted(_ text: String, _ keywords: [String: JSONValue]) -> String {
    let minimum = Int(clamping: keywords["minLength"]?.intValue ?? 0)
    let maximum = keywords["maxLength"]?.intValue.map { Int(clamping: $0) } ?? .max
    var scalars = text.unicodeScalars
    let filler = text.isEmpty ? "-" : " " + text
    while scalars.count < minimum { scalars.append(contentsOf: filler.unicodeScalars) }
    return String(String.UnicodeScalarView(scalars.prefix(maximum)))
  }

  private static func number(_ keywords: [String: JSONValue]) -> Int64 {
    let low = keywords["minimum"]?.intValue ?? 0
    guard let high = keywords["maximum"]?.intValue else { return low }
    return min(low, high)
  }
}
