import Foundation
import ShadowAI
import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

@Suite("Demo samples of Novel Forge schemas", TestTimeLimit.quick)
struct DemoSchemaSampleTests {
  private static let schemas: [(name: String, schema: OrderedJSON)] = [
    ("chapterExpand", chapterExpandSchema), ("chapterFix", chapterFixSchema), ("chapterGeneration", chapterGenerationSchema), ("chapterTitle", chapterTitleSchema),
    ("canonRefreshConstrained", canonRefreshConstrainedSchema), ("chapterJudgeResponse", chapterJudgeResponseSchema), ("chapterJudge", chapterJudgeSchema),
    ("chapterPlanCall", chapterPlanCallSchema), ("chapterSummarize", chapterSummarizeSchema), ("chatCompact", chatCompactSchema), ("chatRefine", chatRefineSchema),
    ("chatTitle", chatTitleSchema), ("continuity", continuitySchema), ("editorialReview", editorialReviewSchema),
  ]

  @Test("should answer every structured call the core makes with JSON its full schema accepts", arguments: schemas.map { $0.name })
  func shouldAnswerEveryStructuredCallWithValidJSON(name: String) async throws {
    let schema = JSONValue(schema: try #require(Self.schemas.first { $0.name == name }).schema)
    let request = ModelRequest(
      model: DemoModelProvider.model, system: [], messages: [.user("Go.")], maxOutputTokens: 1_000, format: .json(name: name, schema: schema))
    let demo = DemoModelProvider(script: DemoScript(fallback: "Demo"), pace: .zero)

    let answer = try #require(await Self.text(demo.stream(request)))

    #expect(StructuredSchema.validate(Data(answer.utf8), against: schema).isEmpty)
  }

  private static func text(_ stream: ModelStream) async -> String? {
    var text = ""
    do throws(ModelError) {
      for try await event in stream { if case .textDelta(let delta) = event { text += delta } }
      return text
    } catch {
      return nil
    }
  }
}
