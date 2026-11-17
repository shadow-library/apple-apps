import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowAI

struct StructuredStreamOutline: Decodable, Sendable {
  let title: String
  let chapters: [Int]
}

enum StructuredStreamFixture {
  static let request = ModelRequest(model: "m", system: [ContextSegment(text: "You outline novels.")], messages: [.user("Outline the novel.")], maxOutputTokens: 512)

  static let schema: JSONValue = [
    "type": "object",
    "properties": ["title": ["type": "string"], "chapters": ["type": "array", "items": ["type": "number"]]],
    "required": ["title", "chapters"],
    "additionalProperties": false,
  ]

  static let review = StructuredReview.decoding(
    StructuredStreamOutline.self,
    postValidate: { outline in zip(outline.chapters, outline.chapters.dropFirst()).contains { $0 >= $1 } ? ["chapters must ascend"] : [] },
    advise: { outline in outline.title.split(separator: " ").count > 3 ? ["the title should be at most three words"] : [] })

  static let ascending = #"{"title":"The Ferry","chapters":[1,2]}"#
  static let descending = #"{"title":"The Ferry","chapters":[2,1]}"#
  static let longTitle = #"{"title":"A Long Ferry Crossing","chapters":[1,2]}"#

  static func describe(_ event: StructuredStreamEvent) -> String {
    switch event {
    case .attemptStarted(let attempt): "attempt \(attempt.number) \(attempt.mode.rawValue) \(attempt.purpose == .answer ? "answer" : "repair")"
    case .textDelta(let text): "delta \(text)"
    case .reset: "reset"
    case .completed(.succeeded): "succeeded"
    case .completed(.failed(let failure)): "failed \(failure.code)"
    }
  }

  static func deltas(_ text: String) -> [String] {
    ScriptedModelProvider.deltas(of: text).map { "delta \($0)" }
  }

  static func response(_ text: String, stop: StopReason = .endTurn) -> ModelResponse {
    ModelResponse(text: text, usage: TokenUsage(input: 10, output: 5), reportedCost: nil, stop: stop, requestID: "req_scripted", generationID: nil)
  }

  static func requests(_ events: [StructuredStreamEvent]) -> [ModelRequest] {
    events.compactMap { event in
      guard case .attemptStarted(let attempt) = event else { return nil }
      return attempt.request
    }
  }

  static func repairIssues(_ events: [StructuredStreamEvent]) -> [JSONSchemaIssue]? {
    for case .attemptStarted(let attempt) in events {
      if case .repair(let issues) = attempt.purpose { return issues }
    }
    return nil
  }
}

@Suite("StructuredCall streaming", .timeLimit(.minutes(1)))
struct StructuredStreamTests {
  private typealias Fixture = StructuredStreamFixture

  private struct Run {
    let outcome: Result<StructuredResult, StructuredStreamFailure>
    let events: [StructuredStreamEvent]

    var lines: [String] { events.map(Fixture.describe) }

    var failure: StructuredStreamFailure? {
      guard case .failure(let failure) = outcome else { return nil }
      return failure
    }

    func result() throws -> StructuredResult {
      try outcome.get()
    }
  }

  private static func stream(
    _ provider: ScriptedModelProvider, native: Bool = false, schema: JSONValue = Fixture.schema, review: StructuredReview = Fixture.review
  ) async -> Run {
    var events: [StructuredStreamEvent] = []
    do throws(StructuredStreamFailure) {
      let result = try await StructuredCall(provider: provider, supportsNativeSchema: native).stream(
        Fixture.request, name: "outline", schema: schema, review: review, observer: { events.append($0) })
      return Run(outcome: .success(result), events: events)
    } catch {
      return Run(outcome: .failure(error), events: events)
    }
  }

  @Test("should stream a first reply that passes every rule and complete with it")
  func firstTry() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.ascending)

    let run = await Self.stream(provider)

    let result = try run.result()
    #expect(run.lines == ["attempt 1 prompt answer"] + Fixture.deltas(Fixture.ascending) + ["succeeded"])
    #expect(run.events.last == .completed(.succeeded(result)))
    #expect(result.json == Data(Fixture.ascending.utf8))
    #expect(!result.wasRepaired)
    #expect(result.responses == [Fixture.response(Fixture.ascending)])
    #expect(result.callIDs.isEmpty)
    #expect(provider.requests.count == 1)
  }

  @Test("should reset the shown text when a repair replaces a reply that broke a blocking rule")
  func repairResets() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.descending)
    provider.enqueueReply(Fixture.ascending)

    let run = await Self.stream(provider)

    let result = try run.result()
    #expect(
      run.lines == ["attempt 1 prompt answer"] + Fixture.deltas(Fixture.descending) + ["attempt 2 prompt repair", "reset"] + Fixture.deltas(Fixture.ascending) + ["succeeded"])
    #expect(Fixture.repairIssues(run.events) == [JSONSchemaIssue(path: "$", message: "chapters must ascend")])
    #expect(provider.requests.last?.messages.last?.text.hasPrefix("That response could not be used. Issues:\n- $: chapters must ascend\n\n") == true)
    #expect(provider.requests.last?.messages.dropLast().last == .assistant(Fixture.descending))
    #expect(result.wasRepaired)
    #expect(result.json == Data(Fixture.ascending.utf8))
    #expect(result.responses == [Fixture.response(Fixture.descending), Fixture.response(Fixture.ascending)])
    #expect(Fixture.requests(run.events) == provider.requests)
  }

  @Test("should keep a first reply with only advisory issues when its one repair is unusable, resetting to it")
  func keepsAdvisoryReply() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.longTitle)
    provider.enqueueReply("I would rather keep that title.")

    let run = await Self.stream(provider)

    let result = try run.result()
    #expect(
      run.lines
        == ["attempt 1 prompt answer"] + Fixture.deltas(Fixture.longTitle) + ["attempt 2 prompt repair", "reset"] + Fixture.deltas("I would rather keep that title.")
        + ["reset", "succeeded"])
    #expect(Fixture.repairIssues(run.events) == [JSONSchemaIssue(path: "$", message: "the title should be at most three words")])
    #expect(result.json == Data(Fixture.longTitle.utf8))
    #expect(!result.wasRepaired)
    #expect(result.responses.count == 2)
    #expect(provider.requests.count == 2)
  }

  @Test("should accept a repair without judging its advice again")
  func repairSkipsAdvice() async throws {
    let provider = ScriptedModelProvider()
    let stillLong = #"{"title":"Another Long Ferry Crossing","chapters":[1,2,3]}"#
    provider.enqueueReply(Fixture.longTitle)
    provider.enqueueReply(stillLong)

    let run = await Self.stream(provider)

    let result = try run.result()
    #expect(result.wasRepaired)
    #expect(result.json == Data(stillLong.utf8))
    #expect(
      run.lines == ["attempt 1 prompt answer"] + Fixture.deltas(Fixture.longTitle) + ["attempt 2 prompt repair", "reset"] + Fixture.deltas(stillLong) + ["succeeded"])
  }

  @Test("should keep a first reply with only advisory issues when its repair is refused")
  func keepsAdvisoryReplyOnRefusedRepair() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.longTitle)
    provider.enqueueReply("No.", stop: .refusal(category: nil))

    let run = await Self.stream(provider)

    let result = try run.result()
    #expect(result.json == Data(Fixture.longTitle.utf8))
    #expect(!result.wasRepaired)
    #expect(result.responses == [Fixture.response(Fixture.longTitle), Fixture.response("No.", stop: .refusal(category: nil))])
    #expect(
      run.lines
        == ["attempt 1 prompt answer"] + Fixture.deltas(Fixture.longTitle) + ["attempt 2 prompt repair", "reset"] + Fixture.deltas("No.") + ["reset", "succeeded"])
  }

  @Test("should keep a first reply with only advisory issues when its repair is cut off")
  func keepsAdvisoryReplyOnTruncatedRepair() async throws {
    let provider = ScriptedModelProvider()
    let cut = #"{"title":"The"#
    provider.enqueueReply(Fixture.longTitle)
    provider.enqueueReply(cut, stop: .maxTokens)

    let run = await Self.stream(provider)

    let result = try run.result()
    #expect(result.json == Data(Fixture.longTitle.utf8))
    #expect(!result.wasRepaired)
    #expect(result.responses == [Fixture.response(Fixture.longTitle), Fixture.response(cut, stop: .maxTokens)])
    #expect(
      run.lines == ["attempt 1 prompt answer"] + Fixture.deltas(Fixture.longTitle) + ["attempt 2 prompt repair", "reset"] + Fixture.deltas(cut) + ["reset", "succeeded"])
  }

  @Test("should call the observer on the caller's actor for every event")
  @MainActor
  func observerOnCallerActor() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.descending)
    provider.enqueueReply(Fixture.ascending)
    var onMain: [Bool] = []

    _ = try await StructuredCall(provider: provider, supportsNativeSchema: false).stream(
      Fixture.request, name: "outline", schema: Fixture.schema, review: Fixture.review, observer: { _ in onMain.append(Thread.isMainThread) })

    #expect(onMain.count == 2 + Fixture.deltas(Fixture.descending).count + Fixture.deltas(Fixture.ascending).count + 2)
    #expect(onMain.allSatisfy { $0 })
  }

  @Test("should decode with the review's own decoder")
  func reviewDecoder() async throws {
    struct Snake: Decodable {
      let chapterCount: Int
    }
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"{"chapter_count":0}"#)
    provider.enqueueReply(#"{"chapter_count":3}"#)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let review = StructuredReview.decoding(Snake.self, decoder: decoder, postValidate: { $0.chapterCount > 0 ? [] : ["a novel needs a chapter"] })
    let schema: JSONValue = ["type": "object", "properties": ["chapter_count": ["type": "integer"]], "required": ["chapter_count"]]

    let run = await Self.stream(provider, schema: schema, review: review)

    #expect(try run.result().json == Data(#"{"chapter_count":3}"#.utf8))
    #expect(Fixture.repairIssues(run.events) == [JSONSchemaIssue(path: "$", message: "a novel needs a chapter")])
  }

  @Test("should carry blocking and advisory issues in one repair and fail when the repair still breaks the blocking rule")
  func failsOnBlockingRule() async {
    let provider = ScriptedModelProvider()
    let both = #"{"title":"A Long Ferry Crossing","chapters":[2,1]}"#
    let stillDescending = #"{"title":"The Ferry","chapters":[3,1]}"#
    provider.enqueueReply(both)
    provider.enqueueReply(stillDescending)

    let run = await Self.stream(provider)

    #expect(
      Fixture.repairIssues(run.events) == [
        JSONSchemaIssue(path: "$", message: "chapters must ascend"), JSONSchemaIssue(path: "$", message: "the title should be at most three words"),
      ])
    #expect(
      run.failure
        == StructuredStreamFailure(
          error: .invalid(issues: [JSONSchemaIssue(path: "$", message: "chapters must ascend")], responses: [Fixture.response(both), Fixture.response(stillDescending)]),
          partialText: "", callIDs: []))
    #expect(run.lines.last == "failed structured.invalid")
  }

  @Test("should report a refusal as a failure with nothing partial")
  func refuses() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply("I can't help with that.", stop: .refusal(category: "policy"))

    let run = await Self.stream(provider)

    #expect(
      run.failure
        == StructuredStreamFailure(
          error: .refused(category: "policy", responses: [Fixture.response("I can't help with that.", stop: .refusal(category: "policy"))]), partialText: "", callIDs: []))
    #expect(run.lines == ["attempt 1 prompt answer"] + Fixture.deltas("I can't help with that.") + ["failed structured.refused"])
    #expect(provider.requests.count == 1)
  }

  @Test("should keep the partial text of a reply that breaks off mid-stream")
  func keepsPartialText() async {
    let provider = ScriptedModelProvider(calls: [
      [.event(.started(requestID: "r1", generationID: nil)), .text(#"{"title":"The Fer"#), .failure(.midStream(code: "overloaded", message: "gone"))]
    ])

    let run = await Self.stream(provider)

    #expect(run.failure == StructuredStreamFailure(error: .model(.midStream(code: "overloaded", message: "gone"), responses: []), partialText: #"{"title":"The Fer"#, callIDs: []))
    #expect(run.lines == ["attempt 1 prompt answer"] + Fixture.deltas(#"{"title":"The Fer"#) + ["failed model.mid_stream"])
  }

  @Test("should keep the first reply and the repair's partial text when the repair breaks off")
  func keepsRepairPartialText() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.descending)
    provider.enqueue([.text(#"{"title":"#), .failure(.transport(.networkConnectionLost))])

    let run = await Self.stream(provider)

    #expect(
      run.failure
        == StructuredStreamFailure(
          error: .model(.transport(.networkConnectionLost), responses: [Fixture.response(Fixture.descending)]), partialText: #"{"title":"#, callIDs: []))
    #expect(run.lines.contains("reset"))
  }

  @Test("should fail an advisory-only first reply whose repair breaks off, as the reference does")
  func advisoryReplyFailsOnBrokenRepair() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.longTitle)
    provider.enqueue([.failure(.server(status: 502))])

    let run = await Self.stream(provider)

    #expect(run.failure?.error == .model(.server(status: 502), responses: [Fixture.response(Fixture.longTitle)]))
  }

  @Test("should repair a reply that fits the schema but does not decode, naming the field")
  func repairsUndecodable() async throws {
    let provider = ScriptedModelProvider()
    let loose: JSONValue = ["type": "object", "properties": ["title": ["type": "string"], "chapters": ["type": "array"]], "required": ["title", "chapters"]]
    provider.enqueueReply(#"{"title":"The Ferry","chapters":["one"]}"#)
    provider.enqueueReply(Fixture.ascending)

    let run = await Self.stream(provider, schema: loose)

    #expect(try run.result().wasRepaired)
    #expect(Fixture.repairIssues(run.events) == [JSONSchemaIssue(path: "$.chapters[0]", message: "could not be read: Expected to decode Int but found a string instead.")])
  }

  @Test("should send a native request again in the prompt form when no model takes the schema, counting both")
  func fallsBackToPrompt() async throws {
    let provider = ScriptedModelProvider(calls: [[.failure(.noEligibleModel)], ScriptedModelProvider.reply(Fixture.ascending)])

    let run = await Self.stream(provider, native: true)

    let result = try run.result()
    #expect(run.lines == ["attempt 1 native answer", "attempt 2 prompt answer"] + Fixture.deltas(Fixture.ascending) + ["succeeded"])
    #expect(result.mode == .prompt)
    #expect(provider.requests.map(\.format) == [.json(name: "outline", schema: Fixture.schema), .text])
  }

  @Test("should not fall back once the native request has shown text")
  func noFallbackAfterText() async {
    let provider = ScriptedModelProvider(calls: [[.text("{"), .failure(.noEligibleModel)]])

    let run = await Self.stream(provider, native: true)

    #expect(run.failure == StructuredStreamFailure(error: .model(.noEligibleModel, responses: []), partialText: "{", callIDs: []))
    #expect(provider.requests.count == 1)
  }

  @Test("should send only the outcome when the schema cannot be checked")
  func unsupportedSchema() async {
    let provider = ScriptedModelProvider()
    let schema: JSONValue = ["type": "object", "properties": ["title": ["type": "string", "pattern": "^[A-Z]"]]]

    let run = await Self.stream(provider, schema: schema)

    #expect(run.lines == ["failed structured.invalid"])
    #expect(provider.requests.isEmpty)
  }

  @Test("should make no request once the call is cancelled")
  func cancelledBeforeStart() async {
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(Fixture.ascending)])

    let run = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await Self.stream(provider)
    }.value

    #expect(run.failure?.error == .model(.cancelled, responses: []))
    #expect(run.lines == ["failed model.cancelled"])
    #expect(provider.requests.isEmpty)
  }

  @Test("should apply the review through the collecting call too")
  func runReviews() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.descending)
    provider.enqueueReply(Fixture.ascending)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(
      Fixture.request, name: "outline", schema: Fixture.schema, review: Fixture.review)

    #expect(result.wasRepaired)
    #expect(result.json == Data(Fixture.ascending.utf8))
  }
}
