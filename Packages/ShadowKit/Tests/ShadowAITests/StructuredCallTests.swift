import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("StructuredCall", .timeLimit(.minutes(1)))
struct StructuredCallTests {
  private struct Judge: Decodable, Equatable {
    struct Finding: Decodable, Equatable {
      let severity: String
      let text: String
    }

    let verdict: String
    let findings: [Finding]
  }

  private static let system = [ContextSegment(text: "You check a chapter against canon.", endsStablePrefix: true), ContextSegment(text: "Chapter 3 of 40.")]
  private static let request = ModelRequest(model: "m", system: system, messages: [.user("Judge chapter 3.")], maxOutputTokens: 1_024)

  private static let finding: JSONValue = [
    "type": "object",
    "properties": [
      "severity": ["type": "string", "enum": ["hard", "soft"], "description": "hard = contradicts established canon and blocks acceptance; soft = wrinkle worth noting"],
      "text": ["type": "string", "description": "one finding, citing the canon it conflicts with (chapter or tracker)"],
    ],
    "required": ["severity", "text"],
    "additionalProperties": false,
  ]

  private static let nativeJudge: JSONValue = [
    "type": "object",
    "properties": ["verdict": ["type": "string", "enum": ["consistent", "contradiction", "evaluation_failed"]], "findings": ["type": "array", "items": finding]],
    "required": ["verdict", "findings"],
    "additionalProperties": false,
  ]

  private static let judge: JSONValue = [
    "type": "object",
    "properties": ["verdict": ["type": "string", "enum": ["consistent", "contradiction", "evaluation_failed"]], "findings": ["type": "array", "items": finding]],
    "required": ["verdict", "findings"],
    "additionalProperties": false,
    "if": ["properties": ["verdict": ["const": "contradiction"]], "required": ["verdict"]],
    "then": [
      "properties": ["findings": ["type": "array", "contains": ["type": "object", "properties": ["severity": ["const": "hard"]], "required": ["severity"]]]],
      "required": ["findings"],
    ],
  ]

  private static let consistent = #"{"verdict":"consistent","findings":[]}"#

  private static func response(_ text: String, stop: StopReason = .endTurn) -> ModelResponse {
    ModelResponse(text: text, usage: TokenUsage(input: 10, output: 5), reportedCost: nil, stop: stop, requestID: "req_scripted", generationID: nil)
  }

  private static func promptRequest(schema: JSONValue) -> ModelRequest {
    var expected = request
    expected.messages = [.user("Judge chapter 3.\n\n" + StructuredPrompt.schemaInstruction(name: "judge", schema: schema))]
    return expected
  }

  private static func failure(_ operation: () async throws(StructuredError) -> StructuredResult) async -> StructuredError? {
    do {
      _ = try await operation()
      return nil
    } catch {
      return error
    }
  }

  @Test("should send a schema that fits as native output in one call")
  func runsNative() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Self.consistent)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: true).run(Self.request, name: "judge", schema: Self.nativeJudge)

    var expected = Self.request
    expected.format = .json(name: "judge", schema: Self.nativeJudge)
    #expect(provider.requests == [expected])
    #expect(result.mode == .native)
    #expect(!result.wasRepaired)
    #expect(result.json == Data(Self.consistent.utf8))
    #expect(result.responses == [Self.response(Self.consistent)])
  }

  @Test("should put the schema in the prompt and leave the system segments unchanged")
  func runsPrompt() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Self.consistent)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)

    let sent = try #require(provider.requests.first)
    #expect(provider.requests == [Self.promptRequest(schema: Self.judge)])
    #expect(sent.system == Self.system)
    #expect(sent.format == .text)
    #expect(sent.messages.last?.text.contains("Respond with ONLY one valid JSON object matching this JSON schema (judge)") == true)
    #expect(sent.messages.last?.text.contains("one finding, citing the canon it conflicts with") == true)
    #expect(result.mode == .prompt)
    #expect(try result.decode(Judge.self) == Judge(verdict: "consistent", findings: []))
  }

  @Test("should send the judge natively without its conditional and still repair a reply that breaks it")
  func repairsNativeConditional() async throws {
    let provider = ScriptedModelProvider()
    let broken = #"{"verdict":"contradiction","findings":[{"severity":"soft","text":"the ward glyph is described twice"}]}"#
    let fixed = #"{"verdict":"contradiction","findings":[{"severity":"hard","text":"the ward glyph is described twice"}]}"#
    provider.enqueueReply(broken)
    provider.enqueueReply(fixed)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: true).run(Self.request, name: "judge", schema: Self.judge)

    #expect(provider.requests.map(\.format) == [.json(name: "judge", schema: Self.nativeJudge), .json(name: "judge", schema: Self.nativeJudge)])
    #expect(result.mode == .native)
    #expect(result.wasRepaired)
    #expect(result.json == Data(fixed.utf8))
  }

  @Test("should use the prompt when the provider cannot take a native schema")
  func fallsBackWithoutNativeSupport() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Self.consistent)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.nativeJudge)

    #expect(provider.requests == [Self.promptRequest(schema: Self.nativeJudge)])
    #expect(result.mode == .prompt)
  }

  @Test("should repair once with the first output and its issues")
  func repairs() async throws {
    let provider = ScriptedModelProvider()
    let broken = #"{"verdict":"contradiction","findings":[{"severity":"soft","text":"the ward glyph is described twice"}]}"#
    let fixed = #"{"verdict":"contradiction","findings":[{"severity":"hard","text":"the ward glyph is described twice"}]}"#
    provider.enqueueReply(broken)
    provider.enqueueReply(fixed)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)

    let issues = [JSONSchemaIssue(path: "$.findings", message: "must contain at least one item of the required shape")]
    var repair = Self.promptRequest(schema: Self.judge)
    repair.messages += [.assistant(broken), .user(StructuredPrompt.repairRequest(issues: issues, previousOutput: broken, schema: Self.judge))]
    #expect(provider.requests == [Self.promptRequest(schema: Self.judge), repair])
    #expect(repair.messages.last?.text.hasPrefix("That response could not be used. Issues:\n- $.findings: must contain at least one item of the required shape\n\n") == true)
    #expect(result.wasRepaired)
    #expect(result.json == Data(fixed.utf8))
    #expect(result.responses == [Self.response(broken), Self.response(fixed)])
  }

  @Test("should fail with the last issues and both responses when the repair is invalid too")
  func failsAfterRepair() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply("not json at all")
    provider.enqueueReply(#"{"verdict":"consistent"}"#)

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)
    }

    let issues = [JSONSchemaIssue(path: "$.findings", message: "is required")]
    #expect(error == .invalid(issues: issues, responses: [Self.response("not json at all"), Self.response(#"{"verdict":"consistent"}"#)]))
    #expect(
      provider.requests.last?.messages.last?.text
        == StructuredPrompt.repairRequest(
          issues: [JSONSchemaIssue(path: "$", message: "is missing: no JSON value was found in the response")], previousOutput: "not json at all", schema: Self.judge))
  }

  @Test("should accept JSON wrapped in prose without a repair")
  func extractsFromProse() async throws {
    let provider = ScriptedModelProvider()
    let raw = "Verdict below.\n{\"verdict\":\"consistent\",\"findings\":[{\"severity\":\"soft\",\"text\":\"the ward sigil closes with a } glyph\"}]}"
    provider.enqueueReply(raw)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)

    #expect(provider.requests.count == 1)
    #expect(try result.decode(Judge.self).findings.first?.text == "the ward sigil closes with a } glyph")
  }

  @Test("should fall back to a later object of the first output when the repair has none")
  func extractsFromFirstAttempt() async throws {
    let provider = ScriptedModelProvider()
    let first = "Two things before I hand you anything invented: {\"note\":\"still thinking\"}\n\nFinal answer:\n{\"verdict\":\"consistent\",\"findings\":[]}"
    provider.enqueueReply(first)
    provider.enqueueReply("I have said all I can say about this chapter.")

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)

    #expect(result.json == Data(Self.consistent.utf8))
    #expect(!result.wasRepaired)
    #expect(result.responses.count == 2)
  }

  @Test("should report a refusal without parsing its text")
  func refuses() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Self.consistent, stop: .refusal(category: "cyber"))

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: true).run(Self.request, name: "judge", schema: Self.nativeJudge)
    }

    #expect(error == .refused(category: "cyber", responses: [Self.response(Self.consistent, stop: .refusal(category: "cyber"))]))
    #expect(provider.requests.count == 1)
  }

  @Test("should report a content filter stop as a refusal")
  func refusesOnContentFilter() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply("{\"verdict\":", stop: .contentFilter)

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)
    }

    #expect(error == .refused(category: "content_filter", responses: [Self.response("{\"verdict\":", stop: .contentFilter)]))
  }

  @Test("should report a cut-off answer without a repair")
  func truncates() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"{"verdict":"consistent","findings":[{"sev"#, stop: .maxTokens)

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)
    }

    #expect(error == .truncated(responses: [Self.response(#"{"verdict":"consistent","findings":[{"sev"#, stop: .maxTokens)]))
    #expect(provider.requests.count == 1)
  }

  @Test("should report a cut-off repair with both responses")
  func truncatesRepair() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply("{}")
    provider.enqueueReply("{\"verdict\":", stop: .maxTokens)

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)
    }

    #expect(error == .truncated(responses: [Self.response("{}"), Self.response("{\"verdict\":", stop: .maxTokens)]))
  }

  @Test("should pass a provider error through")
  func passesModelError() async {
    let provider = ScriptedModelProvider(calls: [[.failure(.overloaded(retryAfter: nil))]])

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: true).run(Self.request, name: "judge", schema: Self.nativeJudge)
    }

    #expect(error == .model(.overloaded(retryAfter: nil), responses: []))
  }

  @Test("should refuse a schema with unsupported keywords before calling the model")
  func refusesUnsupportedSchema() async {
    let provider = ScriptedModelProvider()
    let schema: JSONValue = ["type": "string", "pattern": "^[a-z0-9_]+$"]

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: true).run(Self.request, name: "key", schema: schema)
    }

    #expect(error == .invalid(issues: StructuredSchema.unsupportedKeywords(schema), responses: []))
    #expect(provider.requests.isEmpty)
  }

  @Test("should ask again without an assistant turn when the first answer was blank")
  func repairsBlankAnswer() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply("  ")
    provider.enqueueReply(Self.consistent)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)

    let repair = try #require(provider.requests.last)
    #expect(repair.messages.map(\.role) == [.user, .user])
    #expect(repair.messages.last?.text.hasPrefix("That response was empty. Issues:\n- $: is missing: the response is empty") == true)
    #expect(result.wasRepaired)
  }

  @Test("should keep decimals exactly as the model wrote them")
  func keepsDecimals() async throws {
    let provider = ScriptedModelProvider()
    let text = "```json\n{\"score\": 0.250, \"weight\": 1e-3}\n```"
    provider.enqueueReply(text)
    let schema: JSONValue = [
      "type": "object", "properties": ["score": ["type": "number", "minimum": 0, "maximum": 1], "weight": ["type": "number"]], "required": ["score", "weight"],
      "additionalProperties": false,
    ]

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: true).run(Self.request, name: "score", schema: schema)

    #expect(result.mode == .native)
    let native: JSONValue = [
      "type": "object", "properties": ["score": ["type": "number"], "weight": ["type": "number"]], "required": ["score", "weight"], "additionalProperties": false,
    ]
    #expect(provider.requests.first?.format == .json(name: "score", schema: native))
    #expect(String(decoding: result.json, as: UTF8.self) == #"{"score": 0.250, "weight": 1e-3}"#)
  }

  @Test("should send the native form and repair in native mode what only the full schema rejects")
  func repairsRelaxedConstraint() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"{"title":""}"#)
    provider.enqueueReply(#"{"title":"The Ward"}"#)
    let schema: JSONValue = [
      "type": "object", "properties": ["title": ["type": "string", "minLength": 1, "maxLength": 200]], "required": ["title"], "additionalProperties": false,
    ]
    let native: JSONValue = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: true).run(Self.request, name: "title", schema: schema)

    var expected = Self.request
    expected.format = .json(name: "title", schema: native)
    var repair = expected
    let issues = [JSONSchemaIssue(path: "$.title", message: "must have at least 1 character")]
    repair.messages += [.assistant(#"{"title":""}"#), .user(StructuredPrompt.repairRequest(issues: issues, previousOutput: #"{"title":""}"#, schema: schema))]
    #expect(provider.requests == [expected, repair])
    #expect(result.mode == .native)
    #expect(result.wasRepaired)
    #expect(result.json == Data(#"{"title":"The Ward"}"#.utf8))
  }

  @Test("should report the first billed response when the repair call fails")
  func passesRepairModelError() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply("{}")
    provider.enqueue([.failure(.server(status: 500))])

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)
    }

    #expect(error == .model(.server(status: 500), responses: [Self.response("{}")]))
  }

  @Test("should fail before any call when prompt mode has no user message to carry the schema")
  func refusesPromptWithoutUserTurn() async {
    let provider = ScriptedModelProvider()
    var request = Self.request
    request.messages.append(.assistant("Here is my draft."))

    let error = await Self.failure { () async throws(StructuredError) in
      try await StructuredCall(provider: provider, supportsNativeSchema: false).run(request, name: "judge", schema: Self.judge)
    }

    #expect(error == .model(.invalidRequest("The schema instruction goes on the last message, which must come from the user."), responses: []))
    #expect(provider.requests.isEmpty)
  }

  @Test("should ask for an array in the repair when the schema's root is an array")
  func repairsArray() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"[{"name":"One"}]"#)
    provider.enqueueReply(#"[{"title":"One"}]"#)
    let schema: JSONValue = ["type": "array", "items": ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]]

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "outline", schema: schema)

    let repair = try #require(provider.requests.last?.messages.last?.text)
    #expect(
      repair.hasSuffix(
        "Respond again with ONLY one valid JSON array matching the required schema — fix the listed issues, keep the content, no prose outside the JSON, no markdown fences."))
    #expect(result.wasRepaired)
  }

  @Test("should unwrap a top-level array the model wrapped in an object")
  func unwrapsArray() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"{"chapters":[{"title":"One"},{"title":"Two"}]}"#)
    let schema: JSONValue = ["type": "array", "items": ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]]

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "outline", schema: schema)

    #expect(String(decoding: result.json, as: UTF8.self) == #"[{"title":"One"},{"title":"Two"}]"#)
    #expect(provider.requests.first?.messages.last?.text.contains("Respond with ONLY one valid JSON array") == true)
  }

  @Test("should report a value that does not decode into the requested type")
  func reportsDecodingFailure() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"{"verdict":"consistent","findings":[{"severity":"soft","text":"fine"}]}"#)
    struct Wrong: Decodable { let verdict: Int }

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(Self.request, name: "judge", schema: Self.judge)

    #expect(throws: StructuredError.self) { try result.decode(Wrong.self) }
    #expect(throws: Never.self) { try result.decode(Judge.self) }
  }
}
