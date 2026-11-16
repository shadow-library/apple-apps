import Foundation
import ShadowCore
import Testing

@testable import ShadowAI

@Suite("StructuredSchema")
struct StructuredSchemaTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let label: String
    let schema: JSONValue
    let json: String
    let expected: [JSONSchemaIssue]

    var testDescription: String { label }

    init(_ label: String, _ schema: JSONValue, _ json: String, _ expected: [(String, String)] = []) {
      self.label = label
      self.schema = schema
      self.json = json
      self.expected = expected.map { JSONSchemaIssue(path: $0.0, message: $0.1) }
    }
  }

  private static let chapters: JSONValue = [
    "type": "object",
    "properties": [
      "chapters": [
        "type": "array",
        "items": ["type": "object", "properties": ["title": ["type": "string", "minLength": 1, "maxLength": 200]], "required": ["title"], "additionalProperties": false],
      ]
    ],
    "required": ["chapters"],
    "additionalProperties": false,
  ]

  private static let changeItem: JSONValue = [
    "anyOf": [
      ["type": "object", "properties": ["op": ["type": "string", "enum": ["milestone.remove"]], "milestoneKey": ["type": "string"]], "required": ["op", "milestoneKey"]],
      [
        "type": "object", "properties": ["op": ["type": "string", "enum": ["action.generate_chapter"]], "chapter": ["type": "integer", "minimum": 1]],
        "required": ["op", "chapter"],
      ],
    ]
  ]

  private static let fix: JSONValue = [
    "type": "object",
    "properties": ["action": ["type": "string", "enum": ["patch", "rewrite"]], "patches": ["type": "array"], "body": ["type": "string"]],
    "required": ["action"],
    "if": ["properties": ["action": ["const": "patch"]], "required": ["action"]],
    "then": ["properties": ["patches": ["type": "array", "minItems": 1]], "required": ["patches"]],
    "else": ["properties": ["body": ["type": "string", "minLength": 1]], "required": ["body"]],
  ]

  static let cases: [Case] = [
    Case("type string", ["type": "string"], "1", [("$", "must be a string")]),
    Case("type null in a list", ["type": ["string", "null"]], "null"),
    Case("type list mismatch", ["type": ["string", "null"]], "true", [("$", "must be one of these types: string, null")]),
    Case("integer written as a decimal", ["type": "integer"], "1.0"),
    Case("integer written with an exponent", ["type": "integer"], "1e2"),
    Case("integer beyond Int64", ["type": "integer"], "123456789012345678901234567890"),
    Case("fraction is not an integer", ["type": "integer"], "1.5", [("$", "must be an integer")]),
    Case("number with a small exponent", ["type": "number"], "-1.5E-3"),
    Case("boolean", ["type": "boolean"], "\"true\"", [("$", "must be a boolean")]),
    Case("object", ["type": "object"], "[]", [("$", "must be an object")]),
    Case("array", ["type": "array"], "{}", [("$", "must be an array")]),
    Case("required at a nested path", chapters, #"{"chapters":[{"title":"One"},{"title":"Two"},{}]}"#, [("$.chapters[2].title", "is required")]),
    Case("minLength at a nested path", chapters, #"{"chapters":[{"title":"One"},{"title":"Two"},{"title":""}]}"#, [("$.chapters[2].title", "must have at least 1 character")]),
    Case("maxLength", ["type": "string", "maxLength": 3], "\"four\"", [("$", "must have at most 3 characters")]),
    Case("length counts Unicode scalars", ["type": "string", "maxLength": 2], "\"\u{1F600}\u{1F600}\""),
    Case("combining marks count as scalars", ["type": "string", "maxLength": 1], "\"e\u{301}\"", [("$", "must have at most 1 character")]),
    Case(
      "additionalProperties false", chapters, #"{"chapters":[],"notes":"x"}"#,
      [("$.notes", "is not allowed; the allowed properties are chapters")]),
    Case("additionalProperties true", ["type": "object", "properties": [:], "additionalProperties": true], #"{"anything":1}"#),
    Case(
      "a property name that is not an identifier", ["type": "object", "additionalProperties": false], #"{"two words":1}"#,
      [(#"$["two words"]"#, "is not allowed; the object takes no properties")]),
    Case("items", ["type": "array", "items": ["type": "integer"]], #"[1, "2", 3]"#, [("$[1]", "must be an integer")]),
    Case("enum", ["type": "string", "enum": ["hard", "soft"]], "\"Hard\"", [("$", #"must be one of: "hard", "soft""#)]),
    Case("const", ["const": "patch"], "\"rewrite\"", [("$", #"must be "patch""#)]),
    Case("const equal as a number", ["const": 1], "1.000"),
    Case("const object ignores key order", ["const": ["a": 1, "b": [true, nil]]], #"{"b":[true,null],"a":1}"#),
    Case("minItems", ["type": "array", "minItems": 1], "[]", [("$", "must have at least 1 item")]),
    Case("maxItems", ["type": "array", "maxItems": 2], "[1,2,3]", [("$", "must have at most 2 items")]),
    Case("minimum with a decimal", ["type": "number", "minimum": 1], "0.5", [("$", "must be at least 1")]),
    Case("minimum met", ["type": "integer", "minimum": 1], "1"),
    Case("negative zero meets a minimum of zero", ["type": "number", "minimum": 0, "maximum": 0], "-0"),
    Case("huge exponent beyond a maximum", ["type": "number", "maximum": 10], "1e400", [("$", "must be at most 10")]),
    Case("huge negative exponent below a minimum", ["type": "number", "minimum": -5], "-1e400", [("$", "must be at least -5")]),
    Case("just beyond Int64.max", ["type": "number", "maximum": .int(.max)], "9223372036854775807.5", [("$", "must be at most 9223372036854775807")]),
    Case("tiny positive above zero", ["type": "number", "maximum": 0], "1e-400", [("$", "must be at most 0")]),
    Case("anyOf picks a matching shape", ["type": "array", "items": changeItem], #"[{"op":"milestone.remove","milestoneKey":"m1"},{"op":"action.generate_chapter","chapter":3}]"#),
    Case(
      "anyOf reports the closest shape", ["type": "array", "items": changeItem], #"[{"op":"action.generate_chapter","chapter":0}]"#,
      [("$[0]", "matches none of the 2 allowed shapes; the closest one fails as listed next"), ("$[0].chapter", "must be at least 1")]),
    Case("if and then", fix, #"{"action":"patch","patches":[]}"#, [("$.patches", "must have at least 1 item")]),
    Case("if and else", fix, #"{"action":"rewrite"}"#, [("$.body", "is required")]),
    Case("if satisfied", fix, #"{"action":"rewrite","body":"New text."}"#),
    Case(
      "contains", ["type": "array", "contains": ["properties": ["severity": ["const": "hard"]], "required": ["severity"]]], #"[{"severity":"soft"}]"#,
      [("$", "must contain at least one item of the required shape")]),
    Case("duplicate keys", ["type": "object"], #"{"a":1,"a":2}"#, [("$.a", "appears more than once in the object")]),
    Case("invalid JSON", ["type": "object"], #"{"a":1,}"#, [("$", "is not valid JSON: expected a quoted property name at byte 7")]),
    Case("lone surrogate", ["type": "string"], #""\ud800""#, [("$", "is not valid JSON: a \\u escape is a lone high surrogate at byte 7")]),
    Case(
      "annotations are ignored",
      [
        "type": "string", "description": "a title", "title": "Title", "default": "x", "examples": ["y"], "$comment": "c", "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "t",
      ],
      "\"z\""),
  ]

  @Test("should validate model output against every supported keyword", arguments: cases)
  func validates(_ testCase: Case) {
    #expect(StructuredSchema.validate(Data(testCase.json.utf8), against: testCase.schema) == testCase.expected)
  }

  @Test("should stop collecting issues at the limit")
  func capsIssues() {
    let json = "[" + Array(repeating: "\"x\"", count: 1_000).joined(separator: ",") + "]"
    #expect(StructuredSchema.validate(Data(json.utf8), against: ["type": "array", "items": ["type": "integer"]]).count == StructuredSchema.issueLimit)
  }

  @Test("should reject invalid UTF-8 without trapping")
  func rejectsInvalidUTF8() {
    let issues = StructuredSchema.validate(Data([0x22, 0xFF, 0xFE, 0x22]), against: ["type": "string"])
    #expect(issues == [JSONSchemaIssue(path: "$", message: "is not valid JSON: a string is not valid UTF-8 at byte 3")])
  }

  @Test("should reject nesting beyond the depth limit without trapping")
  func rejectsDeepNesting() {
    let json = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
    #expect(
      StructuredSchema.validate(Data(json.utf8), against: ["type": "array"]) == [JSONSchemaIssue(path: "$", message: "is not valid JSON: nesting deeper than 64 levels at byte 64")]
    )
  }

  @Test("should report keywords the validator does not implement")
  func reportsUnsupportedKeywords() {
    let schema: JSONValue = [
      "type": "object",
      "properties": ["entityKey": ["type": "string", "pattern": "^[a-z0-9_]+$"], "next": ["$ref": "#"]],
      "additionalProperties": ["type": "string"],
    ]
    let expected = [
      JSONSchemaIssue(path: "$.additionalProperties", message: "must be true or false; a schema here is not supported"),
      JSONSchemaIssue(path: "$.properties.entityKey.pattern", message: "uses the keyword pattern, which StructuredSchema.validate does not implement"),
      JSONSchemaIssue(path: #"$.properties.next["$ref"]"#, message: "uses the keyword $ref, which StructuredSchema.validate does not implement"),
    ]
    #expect(StructuredSchema.unsupportedKeywords(schema) == expected)
    #expect(StructuredSchema.validate(Data("{}".utf8), against: schema) == expected)
  }

  @Test("should report malformed keyword values and accept every supported keyword")
  func auditsKeywordValues() {
    #expect(StructuredSchema.unsupportedKeywords(Self.chapters).isEmpty)
    #expect(StructuredSchema.unsupportedKeywords(Self.fix).isEmpty)
    #expect(StructuredSchema.unsupportedKeywords(["type": "array", "items": Self.changeItem, "contains": ["type": "object"]]).isEmpty)
    #expect(
      StructuredSchema.unsupportedKeywords(["type": "text", "minLength": -1, "required": "title", "items": true])
        == [
          JSONSchemaIssue(path: "$.items", message: "must be a schema, which is a JSON object"),
          JSONSchemaIssue(path: "$.minLength", message: "must be a non-negative integer"),
          JSONSchemaIssue(path: "$.required", message: "must be a list of property names"),
          JSONSchemaIssue(path: "$.type", message: "must name a JSON type or a non-empty list of them"),
        ])
  }

  @Test("should find no native issues in a schema that fits")
  func fitsNative() {
    let schema: JSONValue = [
      "type": "object",
      "properties": [
        "verdict": ["type": "string", "enum": ["consistent", "contradiction"]],
        "findings": ["type": "array", "minItems": 1, "items": ["type": "object", "properties": ["text": ["type": "string", "format": "uri"]], "additionalProperties": false]],
        "note": ["type": ["string", "null"]],
      ],
      "required": ["verdict", "findings"],
      "additionalProperties": false,
    ]
    #expect(StructuredSchema.nativeIssues(schema).isEmpty)
    #expect(StructuredSchema.nativeForm(of: schema) == schema)
    #expect(StructuredSchema.relaxedKeywords(schema).isEmpty)
  }

  struct NativeCase: Sendable, CustomTestStringConvertible {
    let label: String
    let property: JSONValue
    let expected: [JSONSchemaIssue]

    var testDescription: String { label }

    init(_ label: String, _ property: JSONValue, _ path: String, _ message: String) {
      self.label = label
      self.property = property
      self.expected = [JSONSchemaIssue(path: path, message: message)]
    }
  }

  private static let nonMonotone = "cannot be sent natively: relaxing the constraints beneath it could reject documents the full schema accepts"

  static let nativeCases: [NativeCase] = [
    NativeCase(
      "a reference", ["$ref": "#"], #"$.properties.field["$ref"]"#, "is a reference; native output is sent only for schemas without references, so recursion is ruled out"),
    NativeCase("an open object", ["type": "object", "properties": [:]], "$.properties.field.additionalProperties", "must be false on every object for native output"),
    NativeCase(
      "an object allowing extra keys", ["type": "object", "additionalProperties": true], "$.properties.field.additionalProperties",
      "must be false on every object for native output"),
    NativeCase(
      "a tuple", ["type": "array", "prefixItems": [["type": "string"]]], "$.properties.field.prefixItems",
      "is a tuple, which native output does not support; removing it would apply items to the prefix"),
    NativeCase("an enum of objects", ["enum": [["a": 1]]], "$.properties.field.enum", "native output supports only scalar enum values"),
    NativeCase("a not", ["not": ["type": "integer", "minimum": 5]], "$.properties.field.not", nonMonotone),
    NativeCase("a oneOf", ["oneOf": [["type": "integer", "minimum": 5], ["type": "integer"]]], "$.properties.field.oneOf", nonMonotone),
    NativeCase(
      "an unevaluatedProperties", ["type": "object", "additionalProperties": false, "unevaluatedProperties": false], "$.properties.field.unevaluatedProperties", nonMonotone),
  ]

  @Test("should report each hard blocker of native output and offer no native form", arguments: nativeCases)
  func reportsNativeBlocker(_ testCase: NativeCase) {
    let schema: JSONValue = ["type": "object", "properties": ["field": testCase.property], "required": ["field"], "additionalProperties": false]
    #expect(StructuredSchema.nativeIssues(schema) == testCase.expected)
    #expect(StructuredSchema.nativeForm(of: schema) == JSONValue?.none)
    #expect(StructuredSchema.relaxedKeywords(schema).isEmpty)
  }

  struct RelaxCase: Sendable, CustomTestStringConvertible {
    let label: String
    let property: JSONValue
    let native: JSONValue
    let relaxed: [JSONSchemaIssue]

    var testDescription: String { label }

    init(_ label: String, _ property: JSONValue, _ native: JSONValue, _ relaxed: [(String, String)]) {
      self.label = label
      self.property = property
      self.native = native
      self.relaxed = relaxed.map { JSONSchemaIssue(path: $0.0, message: $0.1) }
    }
  }

  private static let numeric = "is enforced only in the app: native output does not support numeric constraints"
  private static let length = "is enforced only in the app: native output does not support string length constraints"
  private static let arraySize = "is enforced only in the app: native output supports no array constraint beyond minItems of 0 or 1"
  private static let conditional = "is enforced only in the app: native output does not support conditionals"

  static let relaxCases: [RelaxCase] = [
    RelaxCase("a minimum", ["type": "integer", "minimum": 1], ["type": "integer"], [("$.properties.field.minimum", numeric)]),
    RelaxCase(
      "a maximum and a multipleOf", ["type": "integer", "maximum": 9, "multipleOf": 3], ["type": "integer"],
      [
        ("$.properties.field.maximum", numeric), ("$.properties.field.multipleOf", numeric),
      ]),
    RelaxCase(
      "string lengths", ["type": "string", "minLength": 1, "maxLength": 200], ["type": "string"],
      [
        ("$.properties.field.maxLength", length), ("$.properties.field.minLength", length),
      ]),
    RelaxCase(
      "array sizes", ["type": "array", "maxItems": 5, "uniqueItems": true], ["type": "array"],
      [
        ("$.properties.field.maxItems", arraySize), ("$.properties.field.uniqueItems", arraySize),
      ]),
    RelaxCase(
      "a minItems above one", ["type": "array", "minItems": 2], ["type": "array", "minItems": 1],
      [
        ("$.properties.field.minItems", "is lowered to 1 for native output; the full count is enforced only in the app")
      ]),
    RelaxCase("a minItems of one", ["type": "array", "minItems": 1], ["type": "array", "minItems": 1], []),
    RelaxCase("a contains", ["type": "array", "contains": ["type": "string"]], ["type": "array"], [("$.properties.field.contains", arraySize)]),
    RelaxCase(
      "a conditional with its branches", ["type": "string", "if": ["const": "a"], "then": ["minLength": 2], "else": ["maxLength": 0]], ["type": "string"],
      [("$.properties.field.else", conditional), ("$.properties.field.if", conditional), ("$.properties.field.then", conditional)]),
    RelaxCase(
      "an unsupported format", ["type": "string", "format": "regex"], ["type": "string"],
      [("$.properties.field.format", "is not sent: native output does not support this string format")]),
    RelaxCase("a supported format", ["type": "string", "format": "date-time"], ["type": "string", "format": "date-time"], []),
    RelaxCase(
      "a default", ["type": "boolean", "default": false], ["type": "boolean"], [("$.properties.field.default", "is not sent, as in the reference; it constrains nothing")]),
    RelaxCase(
      "inside anyOf and items", ["type": "array", "items": ["anyOf": [["type": "integer", "minimum": 1], ["type": "null"]]]],
      ["type": "array", "items": ["anyOf": [["type": "integer"], ["type": "null"]]]], [("$.properties.field.items.anyOf[0].minimum", numeric)]),
    RelaxCase(
      "a property named like a keyword",
      ["type": "object", "properties": ["minimum": ["type": "integer", "minimum": 0]], "required": ["minimum"], "additionalProperties": false],
      ["type": "object", "properties": ["minimum": ["type": "integer"]], "required": ["minimum"], "additionalProperties": false],
      [("$.properties.field.properties.minimum.minimum", numeric)]),
  ]

  @Test("should remove what native output cannot express and list it", arguments: relaxCases)
  func relaxes(_ testCase: RelaxCase) {
    func wrapped(_ property: JSONValue) -> JSONValue {
      ["type": "object", "properties": ["field": property], "required": ["field"], "additionalProperties": false, "description": "kept"]
    }
    #expect(StructuredSchema.nativeIssues(wrapped(testCase.property)).isEmpty)
    #expect(StructuredSchema.nativeForm(of: wrapped(testCase.property)) == wrapped(testCase.native))
    #expect(StructuredSchema.relaxedKeywords(wrapped(testCase.property)) == testCase.relaxed)
  }

  private static let referenceFix: JSONValue = [
    "type": "object",
    "properties": [
      "action": ["type": "string", "enum": ["patch", "rewrite"], "description": "patch = targeted find/replace; rewrite = full chapter replacement"],
      "patches": [
        "type": "array",
        "items": [
          "type": "object",
          "properties": ["find": ["type": "string", "minLength": 1], "replace": ["type": "string", "minLength": 1]],
          "required": ["find", "replace"],
          "additionalProperties": false,
        ],
      ],
      "body": ["type": "string", "description": "for rewrite only: complete replacement chapter prose"],
    ],
    "required": ["action"],
    "additionalProperties": false,
    "if": ["properties": ["action": ["const": "patch"]], "required": ["action"]],
    "then": ["properties": ["patches": ["type": "array", "minItems": 1]], "required": ["patches"]],
    "else": ["properties": ["body": ["type": "string", "minLength": 1]], "required": ["body"]],
  ]

  private static let referenceJudge: JSONValue = [
    "type": "object",
    "properties": [
      "verdict": ["type": "string", "enum": ["consistent", "contradiction", "evaluation_failed"]],
      "findings": [
        "type": "array",
        "items": [
          "type": "object", "properties": ["severity": ["type": "string", "enum": ["hard", "soft"]], "text": ["type": "string"]], "required": ["severity", "text"],
          "additionalProperties": false,
        ],
      ],
    ],
    "required": ["verdict", "findings"],
    "additionalProperties": false,
    "if": ["properties": ["verdict": ["const": "contradiction"]], "required": ["verdict"]],
    "then": [
      "properties": ["findings": ["type": "array", "contains": ["type": "object", "properties": ["severity": ["const": "hard"]], "required": ["severity"]]]],
      "required": ["findings"],
    ],
  ]

  @Test("should give the reference's judge and fix schemas a native form while validate still enforces their conditionals")
  func relaxesReferenceConditionals() throws {
    let judge = try #require(StructuredSchema.nativeForm(of: Self.referenceJudge))
    #expect(judge["if"] == nil && judge["then"] == nil)
    #expect(StructuredSchema.relaxedKeywords(Self.referenceJudge).map(\.path) == ["$.if", "$.then"])
    let softContradiction = Data(#"{"verdict":"contradiction","findings":[{"severity":"soft","text":"the ward glyph is described twice"}]}"#.utf8)
    #expect(StructuredSchema.validate(softContradiction, against: judge).isEmpty)
    #expect(
      StructuredSchema.validate(softContradiction, against: Self.referenceJudge)
        == [JSONSchemaIssue(path: "$.findings", message: "must contain at least one item of the required shape")])

    let fix = try #require(StructuredSchema.nativeForm(of: Self.referenceFix))
    #expect(fix["if"] == nil && fix["then"] == nil && fix["else"] == nil)
    let emptyPatch = Data(#"{"action":"patch","patches":[]}"#.utf8)
    let bareRewrite = Data(#"{"action":"rewrite"}"#.utf8)
    #expect(StructuredSchema.validate(emptyPatch, against: fix).isEmpty)
    #expect(StructuredSchema.validate(bareRewrite, against: fix).isEmpty)
    #expect(StructuredSchema.validate(emptyPatch, against: Self.referenceFix) == [JSONSchemaIssue(path: "$.patches", message: "must have at least 1 item")])
    #expect(StructuredSchema.validate(bareRewrite, against: Self.referenceFix) == [JSONSchemaIssue(path: "$.body", message: "is required")])
  }

  @Test("should relax the reference's chapter plan scene schema for native output")
  func relaxesReferenceSchema() throws {
    let scene: JSONValue = [
      "type": "object",
      "properties": [
        "summary": ["type": "string", "minLength": 1, "description": "one sentence the author reads on the plan card: what happens in this scene"],
        "pov": ["type": "string", "description": "entity key of the character whose point of view this scene is told from"],
        "goal": ["type": "string", "minLength": 1],
        "obstacle": ["type": "string", "minLength": 1],
        "turn": ["type": "string", "minLength": 1],
        "beats": ["type": "array", "items": ["type": "string"], "minItems": 1],
        "estimatedWords": ["type": "integer", "minimum": 1],
      ],
      "required": ["summary", "goal", "obstacle", "turn", "beats", "estimatedWords"],
      "additionalProperties": false,
    ]
    let native = try #require(StructuredSchema.nativeForm(of: scene))
    #expect(native["properties"]?["beats"] == ["type": "array", "items": ["type": "string"], "minItems": 1])
    #expect(native["properties"]?["estimatedWords"] == ["type": "integer"])
    #expect(native["properties"]?["summary"]?["description"] != nil)
    #expect(
      StructuredSchema.relaxedKeywords(scene).map(\.path) == [
        "$.properties.estimatedWords.minimum", "$.properties.goal.minLength", "$.properties.obstacle.minLength", "$.properties.summary.minLength", "$.properties.turn.minLength",
      ])
    #expect(StructuredSchema.validate(Data(#"{"summary":"","goal":"g","obstacle":"o","turn":"t","beats":["b"],"estimatedWords":0}"#.utf8), against: native).isEmpty)
  }

  @Test("should block the reviewer's counterexamples, where relaxing beneath not or oneOf would reject a valid document")
  func blocksNonMonotoneCounterexamples() {
    let negated: JSONValue = ["not": ["type": "integer", "minimum": 5]]
    #expect(StructuredSchema.nativeForm(of: negated) == JSONValue?.none)
    #expect(StructuredSchema.nativeIssues(negated).map(\.path) == ["$.not"])

    let exclusive: JSONValue = ["oneOf": [["type": "integer", "minimum": 5], ["type": "integer"]]]
    #expect(StructuredSchema.nativeForm(of: exclusive) == JSONValue?.none)
    #expect(StructuredSchema.nativeIssues(exclusive).map(\.path) == ["$.oneOf"])

    let nested: JSONValue = ["type": "array", "items": ["anyOf": [["type": "string"], negated]]]
    #expect(StructuredSchema.nativeIssues(nested).map(\.path) == ["$.items.anyOf[1].not"])

    let removedWithConditional: JSONValue = ["type": "string", "if": negated, "then": ["minLength": 1]]
    #expect(StructuredSchema.nativeForm(of: removedWithConditional) == ["type": "string"])
  }

  @Test("should report too many optional or union-typed properties for native output")
  func reportsComplexity() {
    var optional: [String: JSONValue] = [:]
    for index in 0..<25 { optional["field\(index)"] = ["type": "string"] }
    #expect(
      StructuredSchema.nativeIssues(.object(["type": "object", "properties": .object(optional), "additionalProperties": false]))
        == [JSONSchemaIssue(path: "$", message: "has 25 optional properties; native output allows at most 24")])
    #expect(StructuredSchema.nativeForm(of: .object(["type": "object", "properties": .object(optional), "additionalProperties": false])) == JSONValue?.none)

    var counted: [String: JSONValue] = [:]
    for index in 0..<20 { counted["field\(index)"] = ["type": "string"] }
    let conditional: JSONValue = .object(["properties": .object(optional)])
    let relaxedAway = JSONValue.object(["type": "object", "properties": .object(counted), "additionalProperties": false, "if": ["required": ["field0"]], "then": conditional])
    #expect(StructuredSchema.nativeIssues(relaxedAway).isEmpty)

    var unions: [String: JSONValue] = [:]
    for index in 0..<17 { unions["field\(index)"] = ["type": ["string", "null"]] }
    let required = JSONValue.array(unions.keys.sorted().map(JSONValue.string))
    #expect(
      StructuredSchema.nativeIssues(.object(["type": "object", "properties": .object(unions), "required": required, "additionalProperties": false]))
        == [JSONSchemaIssue(path: "$", message: "has 17 properties with union types; native output allows at most 16")])
  }
}
