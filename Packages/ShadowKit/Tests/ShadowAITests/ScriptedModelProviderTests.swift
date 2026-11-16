import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("ScriptedModelProvider", .timeLimit(.minutes(1)))
struct ScriptedModelProviderTests {
  private static func request(_ text: String) -> ModelRequest {
    ModelRequest(model: "m", system: [], messages: [.user(text)], maxOutputTokens: 32)
  }

  @Test("should play scripted replies in order and record each request")
  func playsInOrder() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply("First reply", usage: TokenUsage(input: 3, output: 2), reportedCost: Cost(nanoUSD: 7))
    provider.enqueueReply("Second", stop: .maxTokens)

    let first = try await provider.stream(Self.request("one")).collect()
    let second = try await provider.stream(Self.request("two")).collect()

    #expect(
      first
        == ModelResponse(text: "First reply", usage: TokenUsage(input: 3, output: 2), reportedCost: Cost(nanoUSD: 7), stop: .endTurn, requestID: "req_scripted", generationID: nil))
    #expect(second.text == "Second")
    #expect(second.stop == .maxTokens)
    #expect(provider.requests == [Self.request("one"), Self.request("two")])
  }

  @Test("should record a request and take a scripted call only when the stream is first iterated")
  func recordsOnIteration() async throws {
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("Only")])

    _ = provider.stream(Self.request("dropped"))
    let kept = provider.stream(Self.request("kept"))
    #expect(provider.requests.isEmpty)
    #expect(provider.remainingCalls == 1)

    #expect(try await kept.collect().text == "Only")
    #expect(provider.requests == [Self.request("kept")])
    #expect(provider.remainingCalls == 0)
  }

  @Test("should split text into deltas before each run of whitespace")
  func splitsText() async {
    #expect(ScriptedModelProvider.deltas(of: "Hello,  big\nworld") == ["Hello,", "  big", "\nworld"])
    #expect(ScriptedModelProvider.deltas(of: "") == [])
    #expect(ScriptedModelProvider.deltas(of: " lead") == [" lead"])
  }

  @Test("should play events, text and a failure step by step")
  func playsSteps() async {
    let provider = ScriptedModelProvider(calls: [
      [.event(.started(requestID: "r", generationID: "g")), .delay(.milliseconds(1)), .text("a b"), .failure(.overloaded(retryAfter: nil))]
    ])
    var events: [ModelEvent] = []
    let error: ModelError? = await {
      do throws(ModelError) {
        for try await event in provider.stream(Self.request("x")) { events.append(event) }
        return nil
      } catch {
        return error
      }
    }()

    #expect(events == [.started(requestID: "r", generationID: "g"), .textDelta("a"), .textDelta(" b")])
    #expect(error == .overloaded(retryAfter: nil))
  }

  @Test("should fail clearly when more calls are made than were scripted")
  func failsWhenExhausted() async throws {
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("only")])
    _ = try await provider.stream(Self.request("one")).collect()

    await #expect {
      try await provider.stream(Self.request("two")).collect()
    } throws: { error in
      guard case .invalidRequest(let message) = error as? ModelError else { return false }
      return message.contains("stream call 2") && message.contains("1 were scripted")
    }
    await #expect(throws: ModelError.self) { try await provider.models() }
    let credential = try makeCredential("https://openrouter.ai", secret: "sk-or")
    await #expect(throws: ModelError.self) { try await provider.validate(credential) }
    #expect(provider.requests.count == 2)
  }

  @Test("should answer validate and models from their scripts")
  func answersScriptedResults() async throws {
    let provider = ScriptedModelProvider(validations: [.success(.invalid)])
    provider.enqueueValidation(.failure(.authentication))
    provider.enqueueModels(.success([RemoteModel(id: "a")]))
    let credential = try makeCredential("https://openrouter.ai", secret: "sk-or")

    #expect(try await provider.validate(credential) == .invalid)
    await #expect(throws: ModelError.authentication) { try await provider.validate(credential) }
    #expect(try await provider.models() == [RemoteModel(id: "a")])
    #expect(provider.validatedCredentials.map(\.secret) == ["sk-or", "sk-or"])
  }
}
