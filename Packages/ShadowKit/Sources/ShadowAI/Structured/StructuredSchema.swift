import Foundation
import ShadowCore

public enum StructuredSchema {
  static let issueLimit = 100
  static let nativeOptionalPropertyLimit = 24
  static let nativeUnionPropertyLimit = 16

  private static let assertionKeywords: Set<String> = [
    "type", "properties", "required", "additionalProperties", "items", "enum", "const", "minItems", "maxItems", "minLength", "maxLength", "minimum", "maximum",
    "anyOf", "if", "then", "else", "contains",
  ]
  private static let annotationKeywords: Set<String> = ["description", "title", "default", "examples", "$comment", "$schema", "$id"]
  private static let typeNames: Set<String> = ["null", "boolean", "object", "array", "number", "string", "integer"]
  private static let countKeywords: Set<String> = ["minItems", "maxItems", "minLength", "maxLength"]
  private static let schemaListKeywords: Set<String> = ["anyOf", "allOf", "oneOf", "prefixItems"]
  private static let schemaKeywords: Set<String> = ["items", "if", "then", "else", "contains", "not"]
  private static let schemaMapKeywords: Set<String> = ["properties", "$defs", "definitions"]
  private static let nativeReferenceKeywords = ["$ref", "$defs", "definitions"]
  private static let nonMonotoneKeywords: Set<String> = ["not", "oneOf", "unevaluatedProperties", "unevaluatedItems"]
  private static let nativeFormats: Set<String> = ["date-time", "time", "date", "duration", "email", "hostname", "uri", "ipv4", "ipv6", "uuid"]
  private static let relaxedReasons: [String: String] = {
    var reasons: [String: String] = [:]
    for keyword in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"] {
      reasons[keyword] = "is enforced only in the app: native output does not support numeric constraints"
    }
    for keyword in ["minLength", "maxLength"] { reasons[keyword] = "is enforced only in the app: native output does not support string length constraints" }
    for keyword in ["if", "then", "else"] { reasons[keyword] = "is enforced only in the app: native output does not support conditionals" }
    for keyword in ["maxItems", "uniqueItems", "contains", "minContains", "maxContains"] {
      reasons[keyword] = "is enforced only in the app: native output supports no array constraint beyond minItems of 0 or 1"
    }
    for keyword in ["default", "$schema", "$id"] { reasons[keyword] = "is not sent, as in the reference; it constrains nothing" }
    return reasons
  }()

  /// The schema to send as native output: hard blockers make it nil, and constraints native output cannot express are removed, so it only ever accepts more.
  public static func nativeForm(of schema: JSONValue) -> JSONValue? {
    let (relaxed, _) = relaxation(of: schema)
    guard blockers(in: relaxed).isEmpty else { return nil }
    return relaxed
  }

  /// What `nativeForm` removes or lowers, which only the app's validation enforces; empty when the schema cannot be sent natively at all.
  public static func relaxedKeywords(_ schema: JSONValue) -> [JSONSchemaIssue] {
    let (relaxed, removed) = relaxation(of: schema)
    return blockers(in: relaxed).isEmpty ? removed : []
  }

  /// The hard blockers of native output, judged on what would be sent after relaxation; empty means `nativeForm` is non-nil.
  public static func nativeIssues(_ schema: JSONValue) -> [JSONSchemaIssue] {
    blockers(in: relaxation(of: schema).relaxed)
  }

  private static func relaxation(of schema: JSONValue) -> (relaxed: JSONValue, removed: [JSONSchemaIssue]) {
    var removed: [JSONSchemaIssue] = []
    let relaxed = relax(schema, path: [], removed: &removed)
    return (relaxed, removed)
  }

  private static func blockers(in schema: JSONValue) -> [JSONSchemaIssue] {
    var census = NativeCensus()
    census.visit(schema, path: [])
    if census.optionalProperties > nativeOptionalPropertyLimit {
      census.issues.append(
        JSONSchemaIssue(path: "$", message: "has \(census.optionalProperties) optional properties; native output allows at most \(nativeOptionalPropertyLimit)"))
    }
    if census.unionProperties > nativeUnionPropertyLimit {
      census.issues.append(
        JSONSchemaIssue(path: "$", message: "has \(census.unionProperties) properties with union types; native output allows at most \(nativeUnionPropertyLimit)"))
    }
    return census.issues
  }

  /// Keywords `validate` does not implement, and keywords whose value it cannot read: a caller's programming error.
  public static func unsupportedKeywords(_ schema: JSONValue) -> [JSONSchemaIssue] {
    var issues: [JSONSchemaIssue] = []
    audit(schema, path: [], into: &issues)
    return issues
  }

  /// Fails closed: a schema with unsupported keywords yields those as the issues.
  public static func validate(_ json: Data, against schema: JSONValue) -> [JSONSchemaIssue] {
    let unsupported = unsupportedKeywords(schema)
    guard unsupported.isEmpty else { return unsupported }
    do {
      return validate(try StructuredJSONParser.parse(Array(json)), against: schema)
    } catch {
      return [syntaxIssue(error)]
    }
  }

  static func validate(_ value: StructuredJSONValue, against schema: JSONValue) -> [JSONSchemaIssue] {
    var validator = Validator(limit: issueLimit, path: [])
    validator.check(value, schema)
    return validator.issues
  }

  static func syntaxIssue(_ error: StructuredJSONSyntaxError) -> JSONSchemaIssue {
    JSONSchemaIssue(path: "$", message: "is not valid JSON: \(error.reason) at byte \(error.offset)")
  }

  static func rootType(of schema: JSONValue) -> String? {
    schema["type"]?.stringValue
  }

  static func jsonText(_ value: JSONValue) -> String {
    String(decoding: CanonicalJSON.encode(value), as: UTF8.self)
  }

  private static func audit(_ schema: JSONValue, path: [StructuredPathComponent], into issues: inout [JSONSchemaIssue]) {
    guard case .object(let keywords) = schema else {
      issues.append(JSONSchemaIssue(path: StructuredPathComponent.render(path), message: "must be a schema, which is a JSON object"))
      return
    }
    for keyword in keywords.keys.sorted() where !annotationKeywords.contains(keyword) {
      let at = path + [.key(keyword)]
      func report(_ message: String) {
        issues.append(JSONSchemaIssue(path: StructuredPathComponent.render(at), message: message))
      }
      guard assertionKeywords.contains(keyword), let value = keywords[keyword] else {
        report("uses the keyword \(keyword), which StructuredSchema.validate does not implement")
        continue
      }
      switch keyword {
      case "type":
        if !isTypeList(value) { report("must name a JSON type or a non-empty list of them") }
      case "properties":
        guard case .object(let properties) = value else {
          report("must be an object of schemas")
          continue
        }
        for name in properties.keys.sorted() {
          if let property = properties[name] { audit(property, path: at + [.key(name)], into: &issues) }
        }
      case "required":
        if value.arrayValue?.allSatisfy({ $0.stringValue != nil }) != true { report("must be a list of property names") }
      case "additionalProperties":
        if value.boolValue == nil { report("must be true or false; a schema here is not supported") }
      case "enum":
        if value.arrayValue?.isEmpty != false { report("must be a non-empty list") }
      case "const":
        continue
      case "minimum", "maximum":
        if value.intValue == nil { report("must be an integer") }
      case "anyOf":
        guard let branches = value.arrayValue, !branches.isEmpty else {
          report("must be a non-empty list of schemas")
          continue
        }
        for (index, branch) in branches.enumerated() { audit(branch, path: at + [.index(index)], into: &issues) }
      case let keyword where countKeywords.contains(keyword):
        if (value.intValue ?? -1) < 0 { report("must be a non-negative integer") }
      default:
        audit(value, path: at, into: &issues)
      }
    }
  }

  private static func relax(_ schema: JSONValue, path: [StructuredPathComponent], removed: inout [JSONSchemaIssue]) -> JSONValue {
    guard case .object(var keywords) = schema else { return schema }
    for keyword in keywords.keys.sorted() where !nonMonotoneKeywords.contains(keyword) {
      guard let value = keywords[keyword] else { continue }
      let at = path + [.key(keyword)]
      if let reason = relaxedReasons[keyword] {
        keywords[keyword] = nil
        removed.append(JSONSchemaIssue(path: StructuredPathComponent.render(at), message: reason))
      } else if keyword == "format", value.stringValue.map(nativeFormats.contains) != true {
        keywords[keyword] = nil
        removed.append(JSONSchemaIssue(path: StructuredPathComponent.render(at), message: "is not sent: native output does not support this string format"))
      } else if keyword == "minItems", let count = value.intValue, count > 1 {
        keywords[keyword] = 1
        removed.append(JSONSchemaIssue(path: StructuredPathComponent.render(at), message: "is lowered to 1 for native output; the full count is enforced only in the app"))
      } else if schemaKeywords.contains(keyword) || (keyword == "additionalProperties" && value.objectValue != nil) {
        keywords[keyword] = relax(value, path: at, removed: &removed)
      } else if schemaListKeywords.contains(keyword), let branches = value.arrayValue {
        var relaxed: [JSONValue] = []
        for (index, branch) in branches.enumerated() { relaxed.append(relax(branch, path: at + [.index(index)], removed: &removed)) }
        keywords[keyword] = .array(relaxed)
      } else if schemaMapKeywords.contains(keyword), let children = value.objectValue {
        var relaxed: [String: JSONValue] = [:]
        for name in children.keys.sorted() {
          if let child = children[name] { relaxed[name] = relax(child, path: at + [.key(name)], removed: &removed) }
        }
        keywords[keyword] = .object(relaxed)
      }
    }
    return .object(keywords)
  }

  private static func isTypeList(_ value: JSONValue) -> Bool {
    switch value {
    case .string(let name): typeNames.contains(name)
    case .array(let names): !names.isEmpty && names.allSatisfy { $0.stringValue.map(typeNames.contains) == true }
    default: false
    }
  }

  private struct NativeCensus {
    var issues: [JSONSchemaIssue] = []
    var optionalProperties = 0
    var unionProperties = 0

    mutating func visit(_ schema: JSONValue, path: [StructuredPathComponent]) {
      guard case .object(let keywords) = schema else { return }
      func report(_ keyword: String, _ message: String) {
        issues.append(JSONSchemaIssue(path: StructuredPathComponent.render(path + [.key(keyword)]), message: message))
      }
      for keyword in StructuredSchema.nativeReferenceKeywords where keywords[keyword] != nil {
        report(keyword, "is a reference; native output is sent only for schemas without references, so recursion is ruled out")
      }
      if Self.describesObject(keywords), keywords["additionalProperties"] != .bool(false) {
        report("additionalProperties", "must be false on every object for native output")
      }
      if keywords["prefixItems"] != nil { report("prefixItems", "is a tuple, which native output does not support; removing it would apply items to the prefix") }
      for keyword in StructuredSchema.nonMonotoneKeywords.sorted() where keywords[keyword] != nil {
        report(keyword, "cannot be sent natively: relaxing the constraints beneath it could reject documents the full schema accepts")
      }
      if let values = keywords["enum"]?.arrayValue, values.contains(where: { $0.arrayValue != nil || $0.objectValue != nil }) {
        report("enum", "native output supports only scalar enum values")
      }
      if let properties = keywords["properties"]?.objectValue {
        let required = Set(keywords["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        optionalProperties += properties.keys.count(where: { !required.contains($0) })
      }
      if keywords["anyOf"] != nil || (keywords["type"]?.arrayValue?.count ?? 0) > 1 { unionProperties += 1 }
      for keyword in keywords.keys.sorted() {
        guard let value = keywords[keyword] else { continue }
        let at = path + [.key(keyword)]
        if StructuredSchema.schemaKeywords.contains(keyword) || (keyword == "additionalProperties" && value.objectValue != nil) {
          visit(value, path: at)
        } else if StructuredSchema.schemaListKeywords.contains(keyword), let branches = value.arrayValue {
          for (index, branch) in branches.enumerated() { visit(branch, path: at + [.index(index)]) }
        } else if StructuredSchema.schemaMapKeywords.contains(keyword), let children = value.objectValue {
          for name in children.keys.sorted() {
            if let child = children[name] { visit(child, path: at + [.key(name)]) }
          }
        }
      }
    }

    private static func describesObject(_ keywords: [String: JSONValue]) -> Bool {
      switch keywords["type"] {
      case .string("object"): true
      case .array(let names): names.contains(.string("object"))
      default: keywords["properties"] != nil
      }
    }
  }
}

private struct Validator {
  let limit: Int
  var path: [StructuredPathComponent]
  var issues: [JSONSchemaIssue] = []

  var isFull: Bool { issues.count >= limit }

  mutating func check(_ value: StructuredJSONValue, _ schema: JSONValue) {
    guard !isFull, case .object(let keywords) = schema else { return }
    if let type = keywords["type"], !Self.matches(value.node, type: type) {
      report("must be \(Self.describe(type))")
      return
    }
    if let expected = keywords["const"], !Self.equal(value.node, expected) { report("must be \(StructuredSchema.jsonText(expected))") }
    if let allowed = keywords["enum"]?.arrayValue, !allowed.contains(where: { Self.equal(value.node, $0) }) {
      report("must be one of: \(allowed.map(StructuredSchema.jsonText).joined(separator: ", "))")
    }
    switch value.node {
    case .string(let text): checkString(text, keywords)
    case .number(let number): checkNumber(number, keywords)
    case .array(let elements): checkArray(elements, keywords)
    case .object(let members): checkObject(members, keywords)
    case .null, .bool: break
    }
    if let branches = keywords["anyOf"]?.arrayValue { checkAnyOf(value, branches) }
    if let condition = keywords["if"] {
      let branch = passes(value, condition) ? keywords["then"] : keywords["else"]
      if let branch { check(value, branch) }
    }
  }

  private mutating func checkString(_ text: String, _ keywords: [String: JSONValue]) {
    let length = text.unicodeScalars.count
    if let minimum = keywords["minLength"]?.intValue, length < minimum { report("must have at least \(minimum) \(minimum == 1 ? "character" : "characters")") }
    if let maximum = keywords["maxLength"]?.intValue, length > maximum { report("must have at most \(maximum) \(maximum == 1 ? "character" : "characters")") }
  }

  private mutating func checkNumber(_ number: StructuredJSONNumber, _ keywords: [String: JSONValue]) {
    if let minimum = keywords["minimum"]?.intValue, number < StructuredJSONNumber(minimum) { report("must be at least \(minimum)") }
    if let maximum = keywords["maximum"]?.intValue, StructuredJSONNumber(maximum) < number { report("must be at most \(maximum)") }
  }

  private mutating func checkArray(_ elements: [StructuredJSONValue], _ keywords: [String: JSONValue]) {
    if let minimum = keywords["minItems"]?.intValue, elements.count < minimum { report("must have at least \(minimum) \(minimum == 1 ? "item" : "items")") }
    if let maximum = keywords["maxItems"]?.intValue, elements.count > maximum { report("must have at most \(maximum) \(maximum == 1 ? "item" : "items")") }
    if let items = keywords["items"] {
      for (index, element) in elements.enumerated() {
        guard !isFull else { break }
        path.append(.index(index))
        check(element, items)
        path.removeLast()
      }
    }
    if let wanted = keywords["contains"], !elements.contains(where: { passes($0, wanted) }) { report("must contain at least one item of the required shape") }
  }

  private mutating func checkObject(_ members: [StructuredJSONMember], _ keywords: [String: JSONValue]) {
    let properties = keywords["properties"]?.objectValue ?? [:]
    let isClosed = keywords["additionalProperties"] == .bool(false)
    var seen = Set<String>()
    for member in members {
      guard !isFull else { break }
      path.append(.key(member.key))
      if !seen.insert(member.key).inserted {
        report("appears more than once in the object")
      } else if let schema = properties[member.key] {
        check(member.value, schema)
      } else if isClosed {
        report(
          properties.isEmpty ? "is not allowed; the object takes no properties" : "is not allowed; the allowed properties are \(properties.keys.sorted().joined(separator: ", "))")
      }
      path.removeLast()
    }
    for name in keywords["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !seen.contains(name) {
      path.append(.key(name))
      report("is required")
      path.removeLast()
    }
  }

  private mutating func checkAnyOf(_ value: StructuredJSONValue, _ branches: [JSONValue]) {
    var closest: [JSONSchemaIssue]?
    for branch in branches {
      var attempt = Validator(limit: limit, path: path)
      attempt.check(value, branch)
      if attempt.issues.isEmpty { return }
      if attempt.issues.count < closest?.count ?? .max { closest = attempt.issues }
    }
    report("matches none of the \(branches.count) allowed shapes; the closest one fails as listed next")
    for issue in closest ?? [] where !isFull { issues.append(issue) }
  }

  private func passes(_ value: StructuredJSONValue, _ schema: JSONValue) -> Bool {
    var probe = Validator(limit: 1, path: path)
    probe.check(value, schema)
    return probe.issues.isEmpty
  }

  private mutating func report(_ message: String) {
    guard !isFull else { return }
    issues.append(JSONSchemaIssue(path: StructuredPathComponent.render(path), message: message))
  }

  private static func matches(_ node: StructuredJSONNode, type: JSONValue) -> Bool {
    switch type {
    case .string(let name): matches(node, typeName: name)
    case .array(let names): names.contains { $0.stringValue.map { matches(node, typeName: $0) } == true }
    default: false
    }
  }

  private static func matches(_ node: StructuredJSONNode, typeName: String) -> Bool {
    switch (node, typeName) {
    case (.null, "null"), (.bool, "boolean"), (.string, "string"), (.array, "array"), (.object, "object"), (.number, "number"): true
    case (.number(let number), "integer"): number.isInteger
    default: false
    }
  }

  private static func describe(_ type: JSONValue) -> String {
    switch type {
    case .string(let name): article(name)
    case .array(let names): "one of these types: \(names.compactMap(\.stringValue).joined(separator: ", "))"
    default: "of the declared type"
    }
  }

  private static func article(_ typeName: String) -> String {
    switch typeName {
    case "null": "null"
    case "array", "object", "integer": "an \(typeName)"
    default: "a \(typeName)"
    }
  }

  private static func equal(_ node: StructuredJSONNode, _ expected: JSONValue) -> Bool {
    switch (node, expected) {
    case (.null, .null): true
    case (.bool(let actual), .bool(let wanted)): actual == wanted
    case (.number(let actual), .int(let wanted)): actual == StructuredJSONNumber(wanted)
    case (.string(let actual), .string(let wanted)): actual.unicodeScalars.elementsEqual(wanted.unicodeScalars)
    case (.array(let actual), .array(let wanted)): actual.count == wanted.count && zip(actual, wanted).allSatisfy { equal($0.node, $1) }
    case (.object(let actual), .object(let wanted)):
      actual.count == wanted.count && Set(actual.map(\.key)).count == actual.count
        && actual.allSatisfy { member in wanted[member.key].map { equal(member.value.node, $0) } == true }
    default: false
    }
  }
}
