import Foundation
import ShadowCore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import ShadowAI

@Suite("Hard line request guard")
struct HardLineRequestGuardTests {
  private static let explicitHit = HardLineError.declined(source: "The request", rule: .minorWithExplicitAct, sourceRefs: [])

  private static func route(_ mode: ModelContentMode) -> ModelRoute {
    ModelRoute(
      task: .chat, pace: .steady, thinksDeeper: false, deepened: false, contentMode: mode, provider: .openRouter, model: "or/unrestricted", effort: nil,
      maxOutputTokens: 512, supportsNativeSchema: false)
  }

  private static func request(system: [String] = [hardLineSystemLine], messages: [ModelMessage]) -> ModelRequest {
    ModelRequest(model: "or/unrestricted", system: system.map { ContextSegment(text: $0) }, messages: messages, maxOutputTokens: 512)
  }

  private static func refusal(of request: ModelRequest) throws -> HardLineError? {
    let requestGuard = try #require(ModelRequestGuard.hardLine(for: route(.unrestricted)))
    guard case .refuse(let reason) = requestGuard.screen(request) else { return nil }
    return try #require(reason as? HardLineError)
  }

  @Test
  func shouldGuardOnlyAnUnrestrictedRoute() {
    #expect(ModelRequestGuard.hardLine(for: Self.route(.standard)) == nil)
    #expect(ModelRequestGuard.hardLine(for: Self.route(.unrestricted)) != nil)
    #expect(RequestGuard.hardLine(for: Self.route(.unrestricted))?.systemLine == hardLineSystemLine)
    #expect(ModelRequestGuard.hardLine(for: Self.route(.unrestricted))?.systemLine == hardLineSystemLine)
  }

  @Test
  func shouldSendTheSystemLineFirstOnce() throws {
    let requestGuard = try #require(ModelRequestGuard.hardLine(for: Self.route(.unrestricted)))
    let framed = requestGuard.framing(Self.request(system: ["Summarise."], messages: [.user("Go on.")]))
    #expect(framed.system.map(\.text) == [hardLineSystemLine, "Summarise."])
  }

  @Test
  func shouldRefuseAnExplicitTermInAnyTurn() throws {
    #expect(try Self.refusal(of: Self.request(messages: [.user("Go on.")])) == nil)
    #expect(try Self.refusal(of: Self.request(messages: [.user("a child and intercourse")])) == Self.explicitHit)
    #expect(try Self.refusal(of: Self.request(messages: [.user("Summarise."), .assistant("a child and intercourse"), .user("Again.")])) == Self.explicitHit)
    #expect(
      try Self.refusal(of: Self.request(messages: [.assistant("lolicon"), .user("Again.")]))
        == .declined(source: "The request", rule: .standaloneTerm, sourceRefs: []))
  }

  @Test
  func shouldHoldTheWireToTheBackgroundRule() throws {
    #expect(try Self.refusal(of: Self.request(messages: [.user("a child sex")])) == nil)
  }

  @Test
  func shouldScreenTheSystemSegments() throws {
    #expect(try Self.refusal(of: Self.request(system: [hardLineSystemLine, "a child and intercourse"], messages: [.user("Go on.")])) == Self.explicitHit)
    #expect(try Self.refusal(of: Self.request(system: ["a child and intercourse", "Summarise."], messages: [.user("Go on.")])) == Self.explicitHit)
    #expect(try Self.refusal(of: Self.request(system: ["a child and intercourse"], messages: [.user("Go on.")])) == Self.explicitHit)
  }

  @Test
  func shouldScreenEachMessageApart() throws {
    #expect(try Self.refusal(of: Self.request(messages: [.user("a child"), .assistant("intercourse"), .user("Go on.")])) == nil)
    #expect(try Self.refusal(of: Self.request(system: ["a child", "intercourse"], messages: [.user("Go on.")])) == nil)
  }

  @Test
  func shouldReadTheSystemSegmentsAsOneMessageOfParts() {
    let request = Self.request(system: ["a", "b"], messages: [.user("c"), .assistant("d"), .user("e")])
    #expect(wireMessageTexts(request.wireMessages) == ["a\nb", "c", "d", "e"])
    #expect(wireMessageTexts(Self.request(system: [], messages: [.user("c")]).wireMessages) == ["c"])
  }

  @Test
  func shouldScreenTheTextsOpenRouterSends() throws {
    let requests = [
      Self.request(system: [], messages: [.user("a")]),
      Self.request(system: ["s"], messages: [.user("a"), .assistant("b"), .user("c")]),
      ModelRequest(
        model: "or/unrestricted", system: [ContextSegment(text: "s1"), ContextSegment(text: "s2", endsStablePrefix: true), ContextSegment(text: "s3")],
        messages: [.user("a"), .assistant("b"), .user("c")], maxOutputTokens: 512, cachesConversation: true),
      ModelRequest(model: "or/unrestricted", system: [ContextSegment(text: "only", endsStablePrefix: true)], messages: [.user("a")], maxOutputTokens: 512),
    ]
    for request in requests {
      let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OpenRouterRequestBody(request))) as? [String: Any]
      let sent = try #require(body?["messages"] as? [[String: Any]]).map { WireMessage(content: Self.content($0["content"])) }
      #expect(wireMessageTexts(sent) == wireMessageTexts(request.wireMessages))
    }
  }

  private static func content(_ value: Any?) -> HardLineContent {
    if let text = value as? String { return .text(text) }
    guard let parts = value as? [[String: Any]] else { return .other }
    return .parts(parts.map { HardLineContentPart(text: $0["text"] as? String) })
  }

  @Test
  func shouldRefuseARepairThatWouldCarryAFirstReplyBack() async throws {
    let schema: JSONValue = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"], "additionalProperties": false]
    let firstReply = #"{"name":"a child and intercourse"}"#
    let provider = ScriptedModelProvider()
    provider.enqueueReply(firstReply)
    provider.enqueueReply(#"{"title":"Fine"}"#)
    var events: [StructuredStreamEvent] = []

    let failure: StructuredStreamFailure? = await {
      do throws(StructuredStreamFailure) {
        _ = try await StructuredCall(provider: provider, supportsNativeSchema: false).stream(
          Self.request(system: ["Name things."], messages: [.user("Name it.")]), name: "title", schema: schema,
          requestGuard: ModelRequestGuard.hardLine(for: Self.route(.unrestricted)),
          observer: { events.append($0) })
        return nil
      } catch {
        return error
      }
    }()

    let refused = try #require(failure)
    #expect(provider.requests.count == 1)
    #expect(provider.requests.first?.system.map(\.text) == [hardLineSystemLine, "Name things."])
    #expect(refused.code == "AI_015")
    #expect(isHardLineRefusal(refused))
    #expect(isHardLineRefusal(refused.error))
    guard case .model(.requestRefused(let refusal), let responses) = refused.error else {
      Issue.record("expected a refused request, got \(refused.error)")
      return
    }
    #expect(refusal.reason as? HardLineError == Self.explicitHit)
    #expect(refused.error.hardLineHit == HardLineHit(rule: .minorWithExplicitAct, source: "The request", sourceRefs: []))
    #expect(ModelError.requestRefused(refusal).hardLineHit == refused.error.hardLineHit)
    #expect(StructuredError.model(.cancelled, responses: []).hardLineHit == nil)
    #expect(ModelError.requestRefused(ModelRequestRefusal(ModelError.cancelled)).hardLineHit == nil)
    #expect(responses.map(\.text) == [firstReply])
    #expect(refused.partialText.isEmpty)
    #expect(events.count(where: { if case .attemptStarted = $0 { true } else { false } }) == 1)
  }
}
