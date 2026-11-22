import Foundation
import MemoirCore
import ShadowAI
import Testing

@Suite("Demo sample of the insight schema", TestTimeLimit.quick)
struct InsightDemoSampleTests {
  @Test("should answer the insight call with JSON its schema accepts")
  func shouldAnswerTheInsightCallWithValidJSON() async throws {
    let request = ModelRequest(
      model: DemoModelProvider.model, system: [], messages: [.user("Go.")], maxOutputTokens: 1_000,
      format: .json(name: InsightPrompt.schemaName, schema: InsightPrompt.schema))
    var answer = ""
    for try await event in DemoModelProvider(script: DemoScript(fallback: "Demo"), pace: .zero).stream(request) {
      if case .textDelta(let delta) = event { answer += delta }
    }

    #expect(StructuredSchema.validate(Data(answer.utf8), against: InsightPrompt.schema).isEmpty)
  }
}
