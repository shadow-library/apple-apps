import ShadowAI
import ShadowCore
import Testing

@testable import NovelForgeCore

struct PromptSnapshotTests {
  @Test func shouldMatchTheChatRefineSystemPrompt() {
    #expect(sameText(chatRefineSystem, PromptFixture.path("constants", "chatRefineSystem").pText))
    #expect(chatRefineVersion == PromptFixture.path("constants", "chatRefineVersion").pText)
    #expect(Int(PromptFixture.path("constants", "chatRefineStableMessages").numberValue ?? 0) == chatRefineStableMessages)
  }

  @Test func shouldMatchTheCompactAndTitlePrompts() {
    #expect(sameText(chatCompactSystem, PromptFixture.path("constants", "chatCompactSystem").pText))
    #expect(sameText(chatTitleSystem, PromptFixture.path("constants", "chatTitleSystem").pText))
    #expect(chatCompactVersion == PromptFixture.path("constants", "chatCompactVersion").pText)
    #expect(chatTitleVersion == PromptFixture.path("constants", "chatTitleVersion").pText)
  }

  @Test func shouldMatchTheHubPlaybook() {
    #expect(sameText(hubGuidance, PromptFixture.path("constants", "hubGuidance").pText))
    #expect(sameText(hubInstructions, PromptFixture.path("constants", "hubInstructions").pText))
    #expect(hubAllowedOps.map(\.rawValue) == PromptFixture.path("constants", "hubAllowedOps").pStrings)
    #expect(hubContentOps.map(\.rawValue) == PromptFixture.path("constants", "hubContentOps").pStrings)
    #expect(Int(PromptFixture.path("constants", "organiseMinWords").numberValue ?? 0) == organiseMinWords)
  }

  @Test func shouldMatchTheAuthoringPreamble() {
    let expected = PromptFixture.path("constants", "preamble")
    let actual: [String: String] = [
      "authoringStyle": authoringStyle, "authoringStylePlanning": authoringStylePlanning, "editByDeletion": editByDeletion, "clueDiscipline": clueDiscipline,
      "systemPanels": systemPanels, "authoringStyleRepair": authoringStyleRepair, "defaultWritingInstructions": defaultWritingInstructions,
      "bibleStageOutputShape": bibleStageOutputShape,
    ]
    #expect(actual.count == (expected.objectValue?.keys.count ?? -1))
    for (key, text) in actual { #expect(sameText(text, expected.pField(key).pText), "\(key)") }
  }

  @Test func shouldMatchEveryScopeInstructionCase() {
    let cases = PromptFixture.cases("scopeInstructions")
    #expect(cases.count == 5)
    for entry in cases {
      let tools = entry.pField("tools").pItems.map { tool in
        ChatLookupTool(name: tool.pField("name").pText, arguments: tool.pField("args").arrayValue.map { $0.map(\.text) }, description: tool.pField("description").pText)
      }
      #expect(sameText(chatScopeInstructions(tools), entry.pField("text").pText), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchEveryTurnRulesCombination() {
    let cases = PromptFixture.cases("turnRules")
    #expect(cases.count == 20)
    for entry in cases {
      let permissions = ChatTurnPermissions(
        proseEdits: entry.pField("proseEdits").pFlag, justDiscussing: entry.pField("justDiscussing").pFlag, organiseNotes: entry.pField("organiseNotes").pFlag,
        mode: RefinementChatMode(rawValue: entry.pField("mode").pText) ?? .manual)
      #expect(sameText(renderTurnRules(permissions), entry.pField("text").pText), "\(entry)")
    }
  }

  @Test func shouldStartOrganisingOnlyInAutoModeWhenNotJustDiscussing() {
    let starts = PromptFixture.cases("turnRules").filter { $0.pField("text").pText.jsIncludes("starts by itself") }
    #expect(starts.count == 2)
    #expect(starts.allSatisfy { $0.pField("mode").pText == "auto" && !$0.pField("justDiscussing").pFlag && $0.pField("organiseNotes").pFlag })
  }

  @Test func shouldRenderTheTurnMessage() {
    let cases = PromptFixture.cases("turnMessages")
    #expect(cases.count == 12)
    for entry in cases {
      let parts = TurnMessageParts(
        volatileContext: entry.pField("volatileContext").pText, turnRules: entry.pField("turnRules").pText, userMessage: entry.pField("userMessage").pText)
      #expect(sameText(renderTurnMessage(parts), entry.pField("text").pText))
    }
  }

  @Test func shouldLayOutTheChatRefineMessages() {
    let cases = PromptFixture.cases("messages")
    #expect(cases.count == 3)
    for entry in cases {
      let parts = entry.pField("parts")
      let turn = TurnMessageParts(
        volatileContext: parts.pField("volatileContext").pText, turnRules: parts.pField("turnRules").pText, userMessage: parts.pField("userMessage").pText)
      func conversation(_ key: String) -> [PromptMessage] {
        entry.pField(key).pItems.map { PromptMessage($0.pItems[0].pText == "user" ? .user : .assistant, $0.pItems[1].pText) }
      }
      let actual = chatRefineMessages(
        scopeInstructions: entry.pField("scope").pText, stableContext: entry.pField("stable").pText, history: conversation("history"), turn: turn, rounds: conversation("rounds"))
      #expect(sameMessages(actual, entry.pField("expected").pMessages))
    }
  }

  @Test func shouldSplitTheRequestForCachingWithTheSameText() {
    let turn = TurnMessageParts(volatileContext: "v", turnRules: "r", userMessage: "u")
    let history = [PromptMessage(.user, "a"), PromptMessage(.assistant, "b")]
    let rounds = [PromptMessage(.assistant, "c")]
    let parts = ChatRefineRequestParts(scopeInstructions: "S", stableContext: "T", history: history, turn: turn, rounds: rounds)
    let messages = chatRefineMessages(scopeInstructions: "S", stableContext: "T", history: history, turn: turn, rounds: rounds)
    #expect(parts.system.map(\.text) + parts.conversation.map(\.text) == messages.map(\.text))
    #expect(parts.system.map(\.endsStablePrefix) == [false, false, true])
    #expect(sameText(parts.system[0].text, chatRefineSystem))
    #expect(sameMessages(parts.conversation, Array(messages.dropFirst(3))))
  }

  @Test func shouldBuildARequestThatValidates() throws {
    let turn = TurnMessageParts(volatileContext: "v", turnRules: "r", userMessage: "u")
    let parts = ChatRefineRequestParts(scopeInstructions: "S", stableContext: "T", turn: turn)
    let request = ModelRequest(model: "m", system: parts.system, messages: parts.conversation.map { .user($0.text) }, maxOutputTokens: 512)
    #expect(try request.validated() == request)
  }

  @Test func shouldBuildTheCompactMessages() {
    let cases = PromptFixture.cases("compact")
    #expect(cases.count == 3)
    for entry in cases {
      #expect(sameMessages(chatCompactMessages(priorSummary: entry.pField("priorSummary").pText, transcript: entry.pField("transcript").pText), entry.pField("expected").pMessages))
    }
  }

  @Test func shouldBuildTheTitleMessages() {
    let cases = PromptFixture.cases("title")
    #expect(cases.count == 3)
    for entry in cases { #expect(sameMessages(chatTitleMessages(message: entry.pField("message").pText), entry.pField("expected").pMessages)) }
  }

  @Test func shouldMatchTheOutputSchemas() {
    let schemas = PromptFixture.path("schemas")
    #expect(JSONValue(schema: chatRefineSchema) == JSONValue(schema: schemas.pField("refine")))
    #expect(JSONValue(schema: chatRefineConstrainedSchema) == JSONValue(schema: schemas.pField("refineConstrained")))
    #expect(JSONValue(schema: chatCompactSchema) == JSONValue(schema: schemas.pField("compact")))
    #expect(JSONValue(schema: chatTitleSchema) == JSONValue(schema: schemas.pField("title")))
    #expect(Int(schemas.pField("titleMaxLength").numberValue ?? 0) == chatTitleMaxLength)
  }

  @Test func shouldCountThePromptTokensFromTheSystemAndThePlaybook() {
    #expect(chatPromptTokens("") == countTokens(chatRefineSystem) + 64)
    #expect(chatPromptTokens(hubInstructions) == countTokens(chatRefineSystem) + countTokens(hubInstructions) + 64)
  }
}
