import Foundation
import ShadowAI
import ShadowCore
import Testing

@testable import NovelForgeCore

struct ChapterOutputSchemaTests {
  private static let native: [String: OrderedJSON] = [
    "generation": chapterGenerationSchema, "chapterExpand": chapterExpandSchema, "title": chapterTitleSchema, "fix": chapterFixSchema, "judge": chapterJudgeSchema,
    "endingContract": chapterEndingContractSchema,
  ]

  @Test func shouldMatchTheReferenceSchemas() {
    let schemas = ChapterPromptFixture.path("schemas")
    #expect(schemas.objectValue?.keys.count == Self.native.count)
    for (key, schema) in Self.native {
      let expected = schemas.pField(key).pField("schema")
      #expect(JSONValue(schema: schema) == JSONValue(schema: expected), "\(key)")
      #expect(schema.jsonText == expected.jsonText, "\(key)")
    }
  }

  @Test func shouldMatchTheJudgeSchemaSentAsTheResponseFormat() {
    let expected = ChapterPromptFixture.path("schemas", "judge", "constrained")
    #expect(chapterJudgeResponseSchema.jsonText == expected.jsonText)
    #expect(!chapterJudgeResponseSchema.jsonText.contains("\"if\""))
  }

  @Test func shouldAcceptAndRejectEverySampleAsTheReferenceDoes() throws {
    var checked = 0
    for (key, schema) in Self.native {
      let samples = ChapterPromptFixture.path("schemas", key, "samples").pItems
      #expect(samples.count > 4, "\(key)")
      for sample in samples {
        let data = Data(sample.pField("value").jsonText.utf8)
        let issues = StructuredSchema.validate(data, against: JSONValue(schema: schema))
        #expect(issues.isEmpty == sample.pField("valid").pFlag, "\(key) \(sample.pField("name").pText): \(issues)")
        checked += 1
      }
    }
    #expect(checked == 89)
  }

  @Test func shouldDecodeAcceptedGenerationSamples() throws {
    var decoded = 0
    for sample in ChapterPromptFixture.path("schemas", "generation", "samples").pItems where sample.pField("valid").pFlag {
      let output = try JSONDecoder().decode(ChapterDraftOutput.self, from: Data(sample.pField("value").jsonText.utf8))
      #expect(!output.title.isEmpty)
      decoded += 1
    }
    #expect(decoded == 7)
  }

  @Test func shouldDecodeTheGenerationState() throws {
    let json = #"{"title":"t","body":"b","summary":"s","state":{"openConflict":"c","characterPositions":[{"entityKey":"mara","location":"pier"}],"establishedFacts":["f"]}}"#
    let output = try JSONDecoder().decode(ChapterDraftOutput.self, from: Data(json.utf8))
    #expect(output.state == GenerationState(openConflict: "c", characterPositions: [CharacterPosition(entityKey: "mara", location: "pier")], establishedFacts: ["f"]))
  }
}
