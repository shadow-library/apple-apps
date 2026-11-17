import Foundation
import ShadowAI
import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

struct ChatRefineOutputTests {
  private static let scopes = ["project", "novel", "bible_document", "volume", "brief"]

  @Test func shouldValidateEveryHubTurnLikeTheReference() {
    let cases = PromptFixture.cases("validation", "hub")
    #expect(cases.count == 80)
    for entry in cases {
      let errors = validateTurnOutput(entry.pField("output"), allowedOps: hubAllowedOps, lookupsAllowed: entry.pField("scope").pText == "project")
      #expect(
        errors.count == entry.pField("errors").pItems.count && zip(errors, entry.pField("errors").pStrings).allSatisfy { sameText($0, $1) },
        "\(entry.pField("name").pText) \(entry.pField("scope").pText)")
    }
  }

  @Test func shouldValidateWithoutAnAllowlistOrLookupsByDefault() {
    let cases = PromptFixture.cases("validation", "base")
    #expect(cases.count == 16)
    for entry in cases {
      let errors = validateTurnOutput(entry.pField("output"))
      #expect(errors.count == entry.pField("errors").pItems.count && zip(errors, entry.pField("errors").pStrings).allSatisfy { sameText($0, $1) }, "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldAdviseLikeTheReferenceForEveryPermissionCombination() {
    let cases = PromptFixture.cases("advice", "cases")
    #expect(cases.count == 48)
    for entry in cases {
      let issues = adviseTurnOutput(entry.pField("output"), proseEdits: entry.pField("proseEdits").pFlag, organiseNotes: entry.pField("organiseNotes").pFlag)
      #expect(issues.count == entry.pField("issues").pItems.count && zip(issues, entry.pField("issues").pStrings).allSatisfy { sameText($0, $1) }, "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldAdviseWithoutPermissionsLikeProseOffAndNoOrganise() {
    for entry in PromptFixture.cases("advice", "defaults") {
      let issues = adviseTurnOutput(entry.pField("output"), proseEdits: false, organiseNotes: false)
      #expect(issues.count == entry.pField("issues").pItems.count && zip(issues, entry.pField("issues").pStrings).allSatisfy { sameText($0, $1) }, "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldRefuseAChangeSetThatIsNotAnArray() {
    let output = (try? OrderedJSON(parsing: #"{"reply":"r","changeSet":{"op":"premise.update"}}"#)) ?? .null
    #expect(validateTurnOutput(output, allowedOps: hubAllowedOps) == ["changeSet must be an array of operations"])
  }

  @Test func shouldReadATurnOutputFromJSON() throws {
    let json = try OrderedJSON(parsing: #"{"reply":"hi","changeSet":[{"op":"premise.update"}],"lookups":[{"tool":"get_brief","args":{"chapter":2}}],"question":{"question":"q"}}"#)
    let output = try #require(ChatRefineOutput(json: json))
    #expect(output.reply == "hi")
    #expect(output.changeSet?.count == 1)
    #expect(output.lookups?.first?.tool == "get_brief")
    #expect(output.lookups?.first?.args?["chapter"] == .int(2))
    #expect(output.question != nil)
    let replaced = output.replacing(reply: "new", changeSet: nil)
    #expect(replaced.reply == "new" && replaced.changeSet == nil && replaced.lookups == output.lookups)
  }

  @Test func shouldRefuseAnOutputWithoutAReplyOrWithMalformedParts() throws {
    for text in [#"{}"#, #"{"reply":4}"#, #"{"reply":"r","changeSet":["x"]}"#, #"{"reply":"r","lookups":[{"args":{}}]}"#, #"{"reply":"r","lookups":["x"]}"#, "[]"] {
      #expect(ChatRefineOutput(json: try OrderedJSON(parsing: text)) == nil, "\(text)")
    }
    #expect(ChatRefineOutput(data: Data("not json".utf8)) == nil)
  }

  @Test func shouldRepairATurnThatMixesLookupsAndAChangeSet() async throws {
    let mixed = #"{"reply":"r","lookups":[{"tool":"get_brief"}],"changeSet":[{"op":"premise.update","premise":"p"}]}"#
    let fixed = #"{"reply":"r","changeSet":[{"op":"premise.update","premise":"p"}]}"#
    let provider = ScriptedModelProvider()
    provider.enqueueReply(mixed)
    provider.enqueueReply(fixed)
    let request = ModelRequest(model: "m", system: [ContextSegment(text: chatRefineSystem)], messages: [.user("go")], maxOutputTokens: 512)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(
      request, name: "chat-refine", schema: JSONValue(schema: chatRefineSchema), review: chatRefineReview(lookupsAllowed: true))

    #expect(result.wasRepaired)
    #expect(result.json == Data(fixed.utf8))
    #expect(provider.requests.last?.messages.last?.text.contains("return either lookups or a changeSet, never both in one turn") == true)
  }

  @Test func shouldKeepAPlanPageAdvisoryRatherThanBlocking() async throws {
    let plans = #"{"reply":"r","changeSet":[{"op":"bible_document.upsert","section":"plot","slug":"later-plans","body":"The roadmap."}]}"#
    let provider = ScriptedModelProvider()
    provider.enqueueReply(plans)
    provider.enqueueReply("not json at all")
    let request = ModelRequest(model: "m", system: [ContextSegment(text: chatRefineSystem)], messages: [.user("go")], maxOutputTokens: 512)

    let result = try await StructuredCall(provider: provider, supportsNativeSchema: false).run(
      request, name: "chat-refine", schema: JSONValue(schema: chatRefineSchema), review: chatRefineReview(lookupsAllowed: true))

    #expect(result.json == Data(plans.utf8))
  }
}
