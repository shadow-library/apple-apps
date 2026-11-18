import Testing

@testable import NovelForgeCore

struct DraftExpansionParityTests {
  private static let sentence = "She climbed the ridge and did not look back. "
  private static let panel = "```system Status\n\(String(repeating: "Strength rises by one point after the training. ", count: 100))\n```"

  private struct Start: Decodable {
    let words: Int
    let panel: Bool?
  }

  private struct Response: Decodable {
    let words: Int?
    let panel: Bool?
    let error: Bool?
    let noBody: Bool?
    let emptyBody: Bool?
  }

  private struct Project: Decodable {
    let wordTargetMin: Double
    let wordTargetMax: Double
  }

  private struct Call: Decodable {
    let draftWords: Int
    let minWords: Double
    let aimWords: Double
    let missingWords: Double
  }

  private struct Case: Decodable {
    let start: Start
    let responses: [Response]
    let project: Project?
    let maxPasses: Int?
    let calls: [Call]
    let passes: Int
    let initialWords: Int
    let finalWords: Int
    let kept: Int
  }

  private func bodyOfWords(_ words: Int) -> String {
    String(repeating: Self.sentence, count: (words + 8) / 9).jsTrim()
  }

  private func body(of response: Response) -> String? {
    if response.emptyBody == true { return "" }
    guard let words = response.words else { return nil }
    return bodyOfWords(words) + (response.panel == true ? "\n\n\(Self.panel)" : "")
  }

  @Test func shouldMatchTheReferenceExpansionLoop() async throws {
    let cases: [Case] = try GenerationFixtures.load("expansion")
    #expect(cases.count > 70)
    var expanded = 0
    for (index, row) in cases.enumerated() {
      let original = bodyOfWords(row.start.words) + (row.start.panel == true ? "\n\n\(Self.panel)" : "")
      let target = row.project.map { ResolvedWordTarget.resolve(WordTargetSource(wordTargetMin: $0.wordTargetMin, wordTargetMax: $0.wordTargetMax)) } ?? .resolve()
      var requests: [DraftExpansionRequest] = []
      let result = await DraftExpansion.run(body: original, target: target, maxPasses: row.maxPasses ?? DraftExpansion.maxPasses) { request in
        requests.append(request)
        return body(of: row.responses[min(requests.count - 1, row.responses.count - 1)])
      }
      #expect(requests.count == row.calls.count, "calls of case \(index)")
      for (request, call) in zip(requests, row.calls) {
        #expect(
          request.draftWords == call.draftWords && request.minWords == call.minWords && request.aimWords == call.aimWords && request.missingWords == call.missingWords,
          "request of case \(index)")
      }
      #expect(requests.enumerated().allSatisfy { $0.element.pass == $0.offset + 1 }, "pass numbers of case \(index)")
      #expect(result.passes == row.passes && result.initialWords == row.initialWords && result.finalWords == row.finalWords, "result of case \(index)")
      let expectedBody = row.kept == -1 ? original : body(of: row.responses[row.kept])
      #expect(result.body == expectedBody, "body of case \(index)")
      if row.kept >= 0 { expanded += 1 }
    }
    #expect(expanded > 25 && expanded < cases.count - 15)
  }

  @Test func shouldStepThroughTheExpansionOneCheckpointAtATime() {
    let target = ResolvedWordTarget.resolve()
    let short = bodyOfWords(1400)
    var state = DraftExpansion.begin(body: short)
    let first = DraftExpansion.nextRequest(state, target: target)
    #expect(first?.pass == 1 && first?.draftWords == 1404)
    state = DraftExpansion.settle(state, expandedBody: bodyOfWords(1600), target: target)
    #expect(state.passes == 1 && state.words == 1602 && !state.stopped)
    state = DraftExpansion.settle(state, expandedBody: nil, target: target)
    #expect(state.passes == 2 && state.stopped && state.body == bodyOfWords(1600))
    #expect(DraftExpansion.nextRequest(state, target: target) == nil)
    #expect(DraftExpansion.result(state) == DraftExpansionResult(body: bodyOfWords(1600), passes: 2, initialWords: 1404, finalWords: 1602))
  }
}
