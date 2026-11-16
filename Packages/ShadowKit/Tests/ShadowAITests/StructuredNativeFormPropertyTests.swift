import Foundation
import ShadowCore
import Testing

@testable import ShadowAI

@Suite("StructuredSchema.nativeForm properties")
struct StructuredNativeFormPropertyTests {
  private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return mixed ^ (mixed >> 31)
    }
  }

  private struct Generator {
    var random: SplitMix64

    mutating func chance(_ probability: Double) -> Bool {
      Double.random(in: 0..<1, using: &random) < probability
    }

    mutating func int(_ range: ClosedRange<Int64>) -> Int64 {
      Int64.random(in: range, using: &random)
    }

    mutating func schema(depth: Int) -> JSONValue {
      var keywords: [String: JSONValue] = [:]
      if depth > 0, chance(0.03) { return ["not": schema(depth: depth - 1)] }
      if depth > 0, chance(0.03) { return ["oneOf": [schema(depth: depth - 1), schema(depth: depth - 1)]] }
      let kinds = depth > 0 ? ["string", "integer", "number", "boolean", "null", "array", "object", "anyOf"] : ["string", "integer", "number", "boolean", "null"]
      switch kinds.randomElement(using: &random) ?? "null" {
      case "string":
        keywords["type"] = chance(0.2) ? ["string", "null"] : "string"
        if chance(0.4) { keywords["minLength"] = .int(int(0...2)) }
        if chance(0.4) { keywords["maxLength"] = .int(int(0...3)) }
        if chance(0.2) { keywords["enum"] = ["", "a", "bb", nil] }
        if chance(0.25) { keywords["format"] = ["regex", "color", "date", "uuid"].randomElement(using: &random) ?? "regex" }
      case "integer":
        keywords["type"] = "integer"
        if chance(0.5) { keywords["minimum"] = .int(int(-2...2)) }
        if chance(0.5) { keywords["maximum"] = .int(int(-2...2)) }
        if chance(0.2) { keywords["enum"] = [0, 1, 2] }
      case "number":
        keywords["type"] = "number"
        if chance(0.5) { keywords["minimum"] = .int(int(-2...2)) }
        if chance(0.5) { keywords["maximum"] = .int(int(-2...2)) }
      case "boolean":
        keywords["type"] = "boolean"
        if chance(0.3) { keywords["default"] = false }
      case "array":
        keywords["type"] = "array"
        keywords["items"] = schema(depth: depth - 1)
        if chance(0.5) { keywords["minItems"] = .int(int(0...3)) }
        if chance(0.5) { keywords["maxItems"] = .int(int(0...3)) }
        if chance(0.3) { keywords["contains"] = schema(depth: depth - 1) }
      case "object":
        keywords["type"] = "object"
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        let names = ["p0", "minimum", "if", "format", "not", "oneOf"].shuffled(using: &random).prefix(Int(int(0...3)))
        for name in names {
          properties[name] = schema(depth: depth - 1)
          if chance(0.6) { required.append(.string(name)) }
        }
        keywords["properties"] = .object(properties)
        keywords["required"] = .array(required)
        keywords["additionalProperties"] = false
        if let first = names.first, chance(0.4) {
          let target = names.randomElement(using: &random) ?? first
          keywords["if"] = ["properties": [first: ["type": "string"]], "required": [.string(first)]]
          keywords["then"] = chance(0.5) ? ["required": [.string(target)]] : ["properties": [target: ["type": "integer"]]]
          if chance(0.5) { keywords["else"] = ["properties": [target: ["type": "string", "minLength": 1]]] }
        }
      case "anyOf":
        keywords["anyOf"] = [schema(depth: depth - 1), schema(depth: depth - 1)]
      default:
        keywords["type"] = "null"
      }
      if chance(0.2) { keywords["description"] = "generated" }
      return .object(keywords)
    }

    mutating func document(for schema: JSONValue, depth: Int = 0) -> JSONValue {
      if chance(0.05) || depth > 8 { return [nil, 7, "x", true, [:], []].randomElement(using: &random) ?? nil }
      if let branches = schema["anyOf"]?.arrayValue, let branch = branches.randomElement(using: &random) { return document(for: branch, depth: depth + 1) }
      if let values = schema["enum"]?.arrayValue, chance(0.8), let value = values.randomElement(using: &random) { return value }
      let type = schema["type"]?.stringValue ?? schema["type"]?.arrayValue?.randomElement(using: &random)?.stringValue
      switch type {
      case "string": return .string(["", "a", "bb", "ccc", "dddd"].randomElement(using: &random) ?? "")
      case "integer", "number": return .int(int(-3...3))
      case "boolean": return .bool(chance(0.5))
      case "array":
        guard let items = schema["items"] else { return [] }
        return .array((0..<Int(int(0...4))).map { _ in document(for: items, depth: depth + 1) })
      case "object":
        var members: [String: JSONValue] = [:]
        for (name, property) in (schema["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) where chance(0.85) {
          members[name] = document(for: property, depth: depth + 1)
        }
        if chance(0.05) { members["extra"] = 1 }
        return .object(members)
      default: return nil
      }
    }
  }

  /// `validate` does not implement `format`, so validity is compared with every format removed; the property also checks that removing a format touches nothing else.
  private static let subschemaKeywords: Set<String> = ["items", "contains", "not", "if", "then", "else"]
  private static let subschemaListKeywords: Set<String> = ["anyOf", "oneOf"]

  private static func withoutFormats(_ schema: JSONValue) -> JSONValue {
    guard case .object(let keywords) = schema else { return schema }
    var kept: [String: JSONValue] = [:]
    for (keyword, value) in keywords where keyword != "format" {
      switch value {
      case .object(let properties) where keyword == "properties": kept[keyword] = .object(properties.mapValues(withoutFormats))
      case .array(let branches) where subschemaListKeywords.contains(keyword): kept[keyword] = .array(branches.map(withoutFormats))
      case .object where subschemaKeywords.contains(keyword): kept[keyword] = withoutFormats(value)
      default: kept[keyword] = value
      }
    }
    return .object(kept)
  }

  private static func keywordsUsed(in schema: JSONValue) -> Set<String> {
    guard case .object(let keywords) = schema else { return [] }
    var used = Set(keywords.keys)
    for (keyword, value) in keywords {
      switch value {
      case .object(let properties) where keyword == "properties": for property in properties.values { used.formUnion(keywordsUsed(in: property)) }
      case .array(let branches) where subschemaListKeywords.contains(keyword): for branch in branches { used.formUnion(keywordsUsed(in: branch)) }
      case .object where subschemaKeywords.contains(keyword): used.formUnion(keywordsUsed(in: value))
      default: continue
      }
    }
    return used
  }

  @Test("should only loosen: every document valid under the full schema is valid under its native form, and relaxing twice changes nothing")
  func relaxationOnlyLoosens() {
    var generator = Generator(random: SplitMix64(state: 0x5EED))
    var validDocuments = 0
    var looserDocuments = 0
    var blockedByNonMonotone = 0
    var failures: [String] = []
    for _ in 0..<600 {
      let generated = generator.schema(depth: 3)
      let schema = Self.withoutFormats(generated)
      let usesNonMonotone = !Self.keywordsUsed(in: schema).isDisjoint(with: ["not", "oneOf"])
      #expect(StructuredSchema.unsupportedKeywords(schema).isEmpty || usesNonMonotone)
      guard let relaxed = StructuredSchema.nativeForm(of: generated) else {
        let issues = StructuredSchema.nativeIssues(generated)
        let nonMonotone = issues.contains { $0.path.hasSuffix(".not") || $0.path.hasSuffix(".oneOf") }
        #expect(nonMonotone || issues.allSatisfy { $0.path == "$" }, "\(issues)")
        if nonMonotone { blockedByNonMonotone += 1 }
        continue
      }
      #expect(Self.keywordsUsed(in: relaxed).isDisjoint(with: ["not", "oneOf"]))
      #expect(StructuredSchema.nativeForm(of: relaxed) == relaxed)
      #expect(StructuredSchema.relaxedKeywords(relaxed).isEmpty)
      let native = Self.withoutFormats(relaxed)
      #expect(StructuredSchema.nativeForm(of: schema) == native)
      for _ in 0..<25 {
        let json = CanonicalJSON.encode(generator.document(for: schema))
        let validUnderNative = StructuredSchema.validate(json, against: native).isEmpty
        guard StructuredSchema.validate(json, against: schema).isEmpty else {
          if validUnderNative { looserDocuments += 1 }
          continue
        }
        validDocuments += 1
        if !validUnderNative { failures.append("\(StructuredSchema.jsonText(schema)) accepts \(String(decoding: json, as: UTF8.self))") }
      }
    }
    #expect(failures.isEmpty, "\(failures.prefix(3))")
    #expect(validDocuments > 1_000)
    #expect(looserDocuments > 100)
    #expect(blockedByNonMonotone > 10)
  }
}
