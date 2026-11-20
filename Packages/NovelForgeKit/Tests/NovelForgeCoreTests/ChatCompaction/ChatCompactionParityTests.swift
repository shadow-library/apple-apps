import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private struct CompactionFixture: Decodable {
  let historyBudget: Int
  let scenarios: [Scenario]

  struct Scenario: Decodable {
    let name: String
    let novelMode: ContentMode
    let turnMode: ContentMode
    let summary: Summary?
    let messages: [Message]
    let model: String
    let expected: Expected
  }

  struct Summary: Decodable {
    let text: String
    let mode: ContentMode
    let through: Int
  }

  struct Message: Decodable {
    let ordinal: Int
    let role: String
    let content: String
    let contexts: [JSONValue]?
    let question: JSONValue?
    let tokens: Int?
    let mode: ContentMode
  }

  struct Expected: Decodable {
    let outcome: String
    let modelCalled: Bool
    let folded: [Int]?
    let request: Request?
    let referenceMode: ContentMode?
    let nativeMode: ContentMode
    let history: History?
  }

  struct Request: Decodable {
    let priorSummary: String
    let transcript: String
    let text: String
  }

  struct History: Decodable {
    let standard: [Entry]
    let unrestricted: [Entry]?
  }

  struct Entry: Decodable {
    let role: String
    let content: String
  }
}

@Suite("Chat compaction parity", TestTimeLimit.standard)
struct ChatCompactionParityTests {
  private static let fixture: CompactionFixture? = try? ReferenceFixture.decode(from: "chat-compaction/chat-compaction.json")

  @Test func shouldReadTheReferenceHistoryBudget() throws {
    let fixture = try #require(Self.fixture)
    #expect(fixture.historyBudget == ChatContextAssembler.historyBudget)
    #expect(fixture.scenarios.count == 60)
  }

  @Test(arguments: 0..<60)
  func shouldFoldAndRenderAsTheReferenceDoes(_ index: Int) async throws {
    let scenario = try #require(Self.fixture?.scenarios[index])
    let (_, store) = try ChatWorld.store()
    let records = try scenario.messages.map { message in
      try ChatMessageRecord(
        id: CompactionWorld.id(message.ordinal), novel: ChatWorld.novel, session: ChatWorld.session, role: try #require(ChatRole(rawValue: message.role)), content: message.content,
        contexts: message.contexts, contentMode: message.mode, tokens: message.tokens, question: message.question)
    }
    let ordinal = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.id, scenario.messages[$0].ordinal) })
    let prior = try scenario.summary.map { summary in
      try ChatSummaryRecord(
        novel: ChatWorld.novel, session: ChatWorld.session, covered: records.filter { (ordinal[$0.id] ?? 0) <= summary.through }.map(\.id), text: summary.text,
        contentMode: summary.mode)
    }
    try await CompactionWorld.write(records, summary: prior, in: store)

    let window = try await CompactionWorld.window(in: store)
    let plan = window.foldPlan()
    #expect(plan?.folded.compactMap { ordinal[$0.record.id] } == scenario.expected.folded, "\(scenario.name)")
    if let plan, let request = scenario.expected.request {
      #expect(plan.priorSummary.jsEquals(request.priorSummary), "\(scenario.name)")
      #expect(plan.transcript.jsEquals(request.transcript), "\(scenario.name)")
      let mode = window.foldMode(plan, turn: scenario.turnMode, novel: scenario.novelMode)
      #expect(mode == scenario.expected.nativeMode, "\(scenario.name)")
      #expect(scenario.expected.referenceMode != .unrestricted || mode == .unrestricted, "\(scenario.name)")
    }

    let provider = ScriptedModelProvider()
    if scenario.expected.modelCalled { provider.enqueue(CompactionWorld.reply(scenario.model)) }
    let result = try await CompactionWorld.compact(turn: CompactionWorld.turn(scenario.turnMode, novel: scenario.novelMode), store: store, provider: provider)
    switch (result.outcome, scenario.expected.outcome) {
    case (.kept, "kept"), (.refused, "refused"): break
    case (.folded(let id, let mode, _), "folded"):
      #expect(mode == scenario.expected.nativeMode)
      let written = try #require(try await CompactionWorld.summaries(in: store).first { $0.id == id })
      let folded = Set((scenario.expected.folded ?? []).map(CompactionWorld.id))
      #expect(Set(written.covered) == Set(prior?.covered ?? []).union(folded), "\(scenario.name)")
      #expect(written.text.jsEquals(scenario.model))
    default: Issue.record("\(scenario.name): \(result.outcome) against \(scenario.expected.outcome)")
    }
    #expect(provider.requests.count == (scenario.expected.modelCalled ? 1 : 0), "\(scenario.name)")
    if let request = provider.requests.first, let expected = scenario.expected.request {
      let sent = try #require(request.messages.first?.text)
      #expect(request.messages.count == 1 && sent.jsEquals(CompactionWorld.sent(expected.text, in: request)), "\(scenario.name)")
      #expect((request.system.first?.text == hardLineSystemLine) == (scenario.expected.nativeMode == .unrestricted), "\(scenario.name)")
      #expect(request.model == CompactionWorld.unrestrictedModel || scenario.expected.nativeMode == .standard, "\(scenario.name)")
    }

    guard let history = scenario.expected.history else { return }
    for (mode, expected) in [(ContentMode.standard, history.standard), (.unrestricted, history.unrestricted ?? history.standard)] {
      let rendered = result.window.history(for: mode)
      #expect(rendered.count == expected.count, "\(scenario.name) \(mode)")
      for (message, entry) in zip(rendered, expected) {
        #expect(message.role.rawValue == entry.role && message.text.jsEquals(entry.content), "\(scenario.name) \(mode)")
      }
    }
  }
}
