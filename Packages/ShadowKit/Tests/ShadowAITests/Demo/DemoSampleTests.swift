import Foundation
import ShadowCore
import Testing

@testable import ShadowAI

@Suite("DemoSample", TestTimeLimit.quick)
struct DemoSampleTests {
  private static let schemas: [JSONValue] = [
    ["type": "string", "minLength": 30, "maxLength": 32],
    ["type": "string", "maxLength": 2],
    ["type": "integer", "minimum": 3, "maximum": 9],
    ["type": "integer", "maximum": -4],
    ["type": ["null", "boolean"]],
    ["const": ["kind": "note"]],
    ["anyOf": [["type": "integer", "minimum": 5, "maximum": 1], ["type": "string", "minLength": 1]]],
    ["type": "array", "minItems": 3, "maxItems": 3, "items": ["enum": ["a", "b"]]],
    ["type": "array", "maxItems": 0],
    ["type": "array", "items": ["type": "string"], "contains": ["const": "hook"]],
    [
      "type": "object",
      "properties": ["action": ["enum": ["rewrite", "patch"]], "body": ["type": "string"], "patches": ["type": "array", "items": ["type": "string"]]],
      "required": ["action"],
      "if": ["properties": ["action": ["const": "patch"]], "required": ["action"]],
      "then": ["properties": ["patches": ["type": "array", "minItems": 1]], "required": ["patches"]],
      "else": ["properties": ["body": ["type": "string", "minLength": 1]], "required": ["body"]],
    ],
    [
      "type": "object",
      "properties": [
        "cards": ["type": "array", "minItems": 1, "items": ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"], "additionalProperties": false]],
        "note": ["type": "string"],
      ],
      "required": ["cards"],
      "additionalProperties": false,
    ],
  ]

  @Test("should make a value each schema accepts", arguments: schemas)
  func acceptsEverySample(schema: JSONValue) throws {
    let value = try #require(DemoSample.value(for: schema, text: "Demo"))

    #expect(StructuredSchema.validate(CanonicalJSON.encode(value), against: schema).isEmpty)
  }

  @Test("should answer a fix-shaped conditional with the branch its first value meets")
  func meetsTheConditionalBranch() throws {
    let patch: JSONValue = [
      "type": "object",
      "properties": [
        "action": ["enum": ["patch", "rewrite"]],
        "patches": [
          "type": "array",
          "items": [
            "type": "object", "properties": ["find": ["type": "string", "minLength": 1], "replace": ["type": "string", "minLength": 1]],
            "required": ["find", "replace"], "additionalProperties": false,
          ],
        ],
        "body": ["type": "string"],
      ],
      "required": ["action"],
      "additionalProperties": false,
      "if": ["properties": ["action": ["const": "patch"]], "required": ["action"]],
      "then": ["properties": ["patches": ["type": "array", "minItems": 1]], "required": ["patches"]],
      "else": ["properties": ["body": ["type": "string", "minLength": 1]], "required": ["body"]],
    ]

    #expect(DemoSample.value(for: patch, text: "Demo") == ["action": "patch", "patches": [["find": "Demo", "replace": "Demo"]]])
  }

  @Test("should leave an optional list empty and add only the item contains asks for")
  func inventsNoItems() {
    let schema: JSONValue = [
      "type": "object", "properties": ["findings": ["type": "array", "items": ["type": "string"]], "tags": ["type": "array", "contains": ["const": "hook"]]],
      "required": ["findings", "tags"],
    ]

    #expect(DemoSample.value(for: schema, text: "Demo") == ["findings": [], "tags": ["hook"]])
  }

  @Test("should make nothing for a schema no value satisfies")
  func refusesImpossibleSchema() {
    #expect(DemoSample.value(for: ["type": "integer", "minimum": 5, "maximum": 1], text: "Demo") == JSONValue?.none)
  }

  @Test("should read back the name and schema of a schema instruction, and nothing from other text")
  func readsSchemaInstruction() throws {
    let instruction = StructuredPrompt.schemaInstruction(name: "outline", schema: DemoFixture.outline)
    let read = try #require(StructuredPrompt.schemaInstruction(ending: "Outline it.\n\n" + instruction))

    #expect(read.prompt == "Outline it.")
    #expect(read.name == "outline")
    #expect(read.schema == DemoFixture.outline)
    #expect(StructuredPrompt.schemaInstruction(ending: "Outline it.") == nil)
    #expect(StructuredPrompt.schemaInstruction(ending: instruction + "\nAnd one more thing.") == nil)
  }
}
