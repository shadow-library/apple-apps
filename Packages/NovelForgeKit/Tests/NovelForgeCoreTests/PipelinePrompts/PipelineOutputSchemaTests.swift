import Foundation
import ShadowAI
import ShadowCore
import Testing

@testable import NovelForgeCore

struct PipelineOutputSchemaTests {
  private static let hosted: [String: OrderedJSON] = [
    "chapterPlan": chapterPlanSchema, "continuity": continuitySchema, "canonRefresh": canonRefreshSchema, "review": editorialReviewSchema,
    "chapterSummarize": chapterSummarizeSchema,
  ]

  private static let called: [String: OrderedJSON] = [
    "chapterPlan": chapterPlanCallSchema, "continuity": continuitySchema, "canonRefresh": canonRefreshSchema, "review": editorialReviewSchema,
    "chapterSummarize": chapterSummarizeSchema,
  ]

  @Test func shouldMatchTheReferenceSchemaBytes() {
    let schemas = PipelinePromptFixture.path("schemas")
    #expect(schemas.objectValue?.keys.count == Self.hosted.count)
    for (key, schema) in Self.hosted { #expect(schema.jsonText == schemas.pField(key).pField("schema").jsonText, "\(key)") }
  }

  @Test func shouldMatchTheSchemasSentAsTheResponseFormat() {
    let constrained: [String: OrderedJSON] = ["chapterPlan": chapterPlanConstrainedSchema, "canonRefresh": canonRefreshConstrainedSchema]
    for (key, schema) in Self.hosted {
      let expected = PipelinePromptFixture.path("schemas", key, "constrained")
      #expect((constrained[key] ?? schema).jsonText == expected.jsonText, "\(key)")
    }
    #expect(canonRefreshConstrainedSchema.jsonText != canonRefreshSchema.jsonText)
    #expect(chapterPlanConstrainedSchema.jsonText != chapterPlanSchema.jsonText)
  }

  @Test func shouldUseOnlyKeywordsTheStructuredValidatorImplements() {
    for (key, schema) in Self.called { #expect(StructuredSchema.unsupportedKeywords(JSONValue(schema: schema)).isEmpty, "\(key)") }
    #expect(!StructuredSchema.unsupportedKeywords(JSONValue(schema: chapterPlanSchema)).isEmpty)
    #expect(!chapterPlanCallSchema.jsonText.contains("\"pattern\":"))
  }

  @Test func shouldAcceptAndRejectEverySampleAsTheReferenceDoes() throws {
    var checked = 0
    for (key, schema) in Self.called {
      let samples = PipelinePromptFixture.path("schemas", key, "samples").pItems
      #expect(samples.count > 10, "\(key)")
      for sample in samples {
        let name = "\(key) \(sample.pField("name").pText)"
        let data = Data(sample.pField("value").jsonText.utf8)
        let issues = StructuredSchema.validate(data, against: JSONValue(schema: schema))
        let (rules, keys) = Self.reviewIssues(key, data)
        let referenceAccepts = sample.pField("schemaValid").pFlag && sample.pField("reviewIssues").pItems.isEmpty
        #expect((issues.isEmpty && rules.isEmpty && keys.isEmpty) == referenceAccepts, "\(name): \(issues) \(rules) \(keys)")
        if issues.isEmpty && keys.isEmpty { #expect(rules == sample.pField("reviewIssues").pStrings, "\(name)") }
        checked += 1
      }
    }
    #expect(checked == Self.hosted.keys.reduce(0) { $0 + PipelinePromptFixture.path("schemas", $1, "samples").pItems.count })
  }

  private static func reviewIssues(_ key: String, _ data: Data) -> (rules: [String], keys: [String]) {
    guard let json = try? OrderedJSON(parsing: String(decoding: data, as: UTF8.self)) else { return ([], []) }
    switch key {
    case "chapterPlan":
      guard let plan = PlannedChapter(json: json) else { return ([], []) }
      return (chapterPlanIssues(plan), chapterPlanKeyIssues(plan))
    case "canonRefresh": return (canonRefreshIssues(json), [])
    default: return ([], [])
    }
  }
}
