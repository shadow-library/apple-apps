import Foundation
import ShadowCore
import Testing

@testable import ShadowAI

@Suite("ModelRequest")
struct ModelRequestTests {
  private static let valid = ModelRequest(
    model: "claude-sonnet",
    system: [ContextSegment(text: "Canon", endsStablePrefix: true), ContextSegment(text: "Scene")],
    messages: [.user("Hi"), .assistant("Hello"), .user("Write")],
    maxOutputTokens: 1024
  )

  private static func with(_ change: (inout ModelRequest) -> Void) -> ModelRequest {
    var request = valid
    change(&request)
    return request
  }

  private static let schema = JSONValue.object(["type": .string("object")])

  @Test("should default effort, format and conversation caching")
  func defaultsTrailingParameters() {
    #expect(Self.valid.effort == nil)
    #expect(Self.valid.format == .text)
    #expect(Self.valid.cachesConversation == false)
  }

  @Test(
    "should accept well-formed requests unchanged",
    arguments: [
      valid,
      with { $0.system = [] },
      with { $0.messages = [.user("Only")] },
      with { $0.maxOutputTokens = 1 },
      with { $0.format = .json(name: "chapter_plan-2", schema: schema) },
      with { $0.format = .json(name: String(repeating: "a", count: 64), schema: schema) },
    ]
  )
  func acceptsWellFormed(request: ModelRequest) throws {
    #expect(try request.validated() == request)
  }

  @Test(
    "should reject malformed requests",
    arguments: [
      with { $0.model = "" },
      with { $0.model = "  " },
      with { $0.messages = [] },
      with { $0.messages = [.user("Hi"), .assistant("Prefill")] },
      with { $0.messages = [.user("Hi"), .assistant(""), .user("Go")] },
      with { $0.messages = [.user(" \n\t")] },
      with { $0.system = [ContextSegment(text: "", endsStablePrefix: true)] },
      with { $0.system = [ContextSegment(text: "Canon"), ContextSegment(text: "  ")] },
      with { $0.maxOutputTokens = 0 },
      with { $0.maxOutputTokens = -5 },
      with { $0.system = [ContextSegment(text: "A", endsStablePrefix: true), ContextSegment(text: "B", endsStablePrefix: true)] },
      with { $0.format = .json(name: "", schema: schema) },
      with { $0.format = .json(name: "has space", schema: schema) },
      with { $0.format = .json(name: String(repeating: "a", count: 65), schema: schema) },
      with { $0.format = .json(name: "plan", schema: .array([])) },
    ]
  )
  func rejectsMalformed(request: ModelRequest) {
    #expect {
      try request.validated()
    } throws: { error in
      guard let error = error as? ModelError, case .invalidRequest(let message) = error else { return false }
      return !message.isEmpty
    }
  }
}

@Suite("Effort")
struct EffortTests {
  @Test("should pin raw values in ascending order")
  func pinsRawValues() {
    #expect(Effort.allCases.map(\.rawValue) == ["low", "medium", "high", "xhigh", "max"])
    #expect(Effort.allCases.sorted() == Effort.allCases)
    #expect(Effort.low < .medium && Effort.medium < .high && Effort.high < .xhigh && Effort.xhigh < .max)
  }

  @Test("should raise one level and stay at the top", arguments: [(Effort.low, Effort.medium), (.medium, .high), (.high, .xhigh), (.xhigh, .max), (.max, .max)])
  func raisesOneLevel(effort: Effort, expected: Effort) {
    #expect(effort.raised == expected)
  }
}

@Suite("TokenUsage and Cost")
struct UsageTests {
  @Test("should add usage field by field")
  func addsUsage() {
    let lhs = TokenUsage(input: 1, output: 2, cacheRead: 3, cacheWriteShort: 4, cacheWriteLong: 5)
    let rhs = TokenUsage(input: 10, output: 20, cacheRead: 30, cacheWriteShort: 40, cacheWriteLong: 50)
    #expect(lhs + rhs == TokenUsage(input: 11, output: 22, cacheRead: 33, cacheWriteShort: 44, cacheWriteLong: 55))
    #expect(lhs + .zero == lhs)
    #expect(TokenUsage.zero == TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWriteShort: 0, cacheWriteLong: 0))
  }

  @Test("should add, subtract and compare costs in whole nano-dollars")
  func doesCostArithmetic() {
    let dollar = Cost(nanoUSD: Cost.nanoUSDPerUSD)
    let cent = Cost(nanoUSD: 10_000_000)
    #expect(dollar + cent == Cost(nanoUSD: 1_010_000_000))
    #expect(dollar - cent == Cost(nanoUSD: 990_000_000))
    #expect(cent < dollar)
    #expect([dollar, cent, .zero].sorted() == [.zero, cent, dollar])
    #expect([cent, cent, cent].reduce(.zero, +) == Cost(nanoUSD: 30_000_000))
  }

  @Test("should encode a cost as a bare integer")
  func encodesCostAsInteger() throws {
    let data = try JSONEncoder().encode(Cost(nanoUSD: 1_500))
    #expect(String(decoding: data, as: UTF8.self) == "1500")
    #expect(try JSONDecoder().decode(Cost.self, from: data) == Cost(nanoUSD: 1_500))
  }
}
